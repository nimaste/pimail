import Foundation
import JMAPKit
import OSLog

/// Whether a failed action is worth keeping.
///
/// The whole offline queue turns on this one distinction, and getting it wrong
/// is worse in both directions: queue a refusal and the client replays it
/// forever, against a server that will go on saying no; discard a transport
/// failure and the conversation the user archived on a train comes back.
public enum ActionFailure: Hashable, Sendable {
    /// This device is right and the server has not caught up. Keep it.
    case transport
    /// The server considered the change and said no. Put the row back.
    case refusal

    /// Whether the change should be queued.
    public var isQueueWorthy: Bool { self == .transport }

    /// Reads an error the way the user's mailbox will experience it.
    ///
    /// A rejected credential counts as a refusal rather than as a transport
    /// failure: an app password that was revoked stays revoked, so queueing
    /// against it would build a backlog that can only ever be replayed into the
    /// same 401. The same argument applies to an untrusted certificate, which
    /// needs a person to look at a fingerprint before anything is sent again.
    ///
    /// An unrecognised error is a refusal, deliberately. Queueing is the
    /// destructive default — it leaves the local cache disagreeing with the
    /// server until something drains — so anything this cannot name is put back
    /// on screen where the user can see it instead.
    public static func classify(_ error: any Error) -> ActionFailure {
        if error is CancellationError {
            // The app was backgrounded or the task torn down mid-send. Nothing
            // was learned about the server, and losing the gesture because the
            // user switched apps is exactly the failure this queue exists for.
            return .transport
        }

        if error is URLError { return .transport }

        guard let error = error as? JMAPError else { return .refusal }

        switch error {
        case .unreachable:
            return .transport
        case .unexpectedStatus:
            // A reverse proxy answering 502 while the NAS finishes booting is
            // not the mail server refusing anything.
            return .transport
        case .malformedResponse:
            // The request may well have been applied; the answer was simply
            // unreadable. Every mutation here is idempotent except a trash,
            // and a re-sent destroy of an already-trashed message comes back
            // as `notDestroyed` and is dropped as a refusal on the next pass.
            return .transport
        case .notAuthenticated, .untrustedCertificate, .methodFailed, .requestFailed,
            .noSuchCall:
            return .refusal
        }
    }
}

/// Empties the offline action queue, slowly and in order.
///
/// **Never eager.** This audience runs plMail on a NAS or a Raspberry Pi with a
/// single PHP worker pool, so a drain that retried on a timer would take the
/// server down for the browser tab as well. It runs when something suggests the
/// server is back — the network path changed, the app came forward, a sync
/// succeeded — and backs off exponentially between failures.
///
/// Sending is injected rather than built here: what a ``PendingMutation``
/// becomes on the wire needs a label binding resolved per account and lives
/// with the code that built it, and a closure is what lets the ordering rules
/// below be tested without a server.
public actor ActionDrain {
    /// One attempt's outcome, as the queue needs to hear it.
    public enum Attempt: Hashable, Sendable {
        /// Accepted, or no longer meaningful — a label that no longer resolves
        /// counts as sent, because a queue that cannot empty blocks every
        /// action behind it forever.
        case sent
        /// The server said no. Not retried: replaying a refusal is a loop that
        /// terminates never.
        case refused(String)
        /// Nothing was learned. Everything behind this stays put.
        case unreachable
    }

    /// What one drain did, for the banner and for the log.
    public struct Summary: Hashable, Sendable {
        public var sent = 0
        public var refused = 0
        /// Still waiting when the drain stopped.
        public var remaining = 0
        /// True when the drain stopped at a transport failure rather than at
        /// the end of the queue — which is what the caller reports as "still
        /// waiting for nas.local" rather than "done".
        public var stoppedEarly = false
        /// True when nothing was attempted because the backoff had not
        /// elapsed. Distinct from an empty queue: a caller must not report
        /// "everything sent" for a pass that never tried.
        public var wasDeferred = false
    }

    private let queue: ActionQueue
    private let policy: RetryPolicy
    private let logger = Logger(subsystem: "de.plmail", category: "actions")

    /// Earliest the next attempt may be made.
    ///
    /// Set from ``RetryPolicy/delay(forAttempt:)`` on every transport failure.
    /// Without it, a network path that flaps — a phone at the edge of a cell —
    /// would produce one full drain attempt per flap.
    private var nextAttempt: Date?
    private var consecutiveFailures = 0

    /// Guards against two drains overlapping.
    ///
    /// A foreground and a network-path change routinely arrive within the same
    /// second; two passes over one directory would send the head mutation
    /// twice, and an archive sent twice after an undo is mail the user cannot
    /// get back without going to the server.
    private var isDraining = false

    public init(queue: ActionQueue, policy: RetryPolicy = RetryPolicy()) {
        self.queue = queue
        self.policy = policy
    }

    /// How many changes are waiting. Read for the banner.
    public func pendingCount() async -> Int {
        await queue.count()
    }

    /// Sends what is waiting, oldest first, stopping at the first transport
    /// failure.
    ///
    /// Order is preserved and the failing item is left at the head: star then
    /// unstar do not commute, so skipping past a stuck mutation to send the one
    /// behind it would leave the server in a state nobody asked for.
    ///
    /// - Parameters:
    ///   - now: Injected so the backoff can be tested without sleeping.
    ///   - send: Performs one mutation.
    /// - Returns: What was sent, refused and left behind, and whether the pass
    ///   stopped early — which is the difference between "everything is on the
    ///   server" and "still waiting for the server".
    @discardableResult
    public func drain(
        now: Date = .now,
        send: @Sendable (PendingMutation) async -> Attempt
    ) async -> Summary {
        var summary = Summary()

        guard isDraining == false else {
            summary.remaining = await queue.count()
            summary.wasDeferred = true

            return summary
        }

        if let nextAttempt, now < nextAttempt {
            summary.remaining = await queue.count()
            summary.wasDeferred = true

            return summary
        }

        isDraining = true
        defer { isDraining = false }

        let waiting = await queue.pending()

        guard waiting.isEmpty == false else {
            consecutiveFailures = 0
            nextAttempt = nil

            return summary
        }

        for mutation in waiting {
            // A drain is cancellable — it runs from a background refresh with
            // an expiration handler — and stopping mid-queue must leave the
            // remainder on disk rather than losing it.
            if Task.isCancelled {
                summary.stoppedEarly = true
                break
            }

            switch await send(mutation) {
            case .sent:
                await queue.remove(mutation.id)
                summary.sent += 1

            case .refused(let reason):
                // Dropped, not retried, and counted so the caller can say what
                // the server would not do.
                await queue.remove(mutation.id)
                summary.refused += 1
                logger.error("Dropped a refused action: \(reason, privacy: .public)")

            case .unreachable:
                var retried = mutation
                retried.attempts += 1
                await queue.update(retried)

                consecutiveFailures += 1
                nextAttempt = now.advanced(
                    by: TimeInterval(policy.delay(forAttempt: consecutiveFailures)))
                summary.stoppedEarly = true

                summary.remaining = await queue.count()

                return summary
            }
        }

        consecutiveFailures = 0
        nextAttempt = nil
        summary.remaining = await queue.count()

        return summary
    }

    /// Forgets the backoff, for the one signal worth acting on: the network
    /// path changed, or the user asked directly. Time passing is not evidence.
    public func allowRetry() {
        nextAttempt = nil
        consecutiveFailures = 0
    }
}

extension TimeInterval {
    /// Seconds from a `Duration`, for the one place a wall-clock deadline is
    /// needed. `Duration` has no `timeIntervalSince`, and rebuilding this
    /// conversion at each call site is how two of them come to disagree.
    fileprivate init(_ duration: Duration) {
        let components = duration.components

        self = Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
