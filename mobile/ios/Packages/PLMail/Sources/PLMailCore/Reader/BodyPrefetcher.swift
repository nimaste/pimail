import Foundation
import JMAPKit
import OSLog

/// Fetches message bodies ahead of being asked for them, so a conversation
/// opened on a train has something to show.
///
/// "It works with no signal" is this app's headline promise, and today it is
/// only true for threads that happen to have been opened before. The cost of
/// making it true in general is paid by the server, and the server is
/// somebody's Raspberry Pi with one PHP worker pool — so every knob here is a
/// brake, not an accelerator:
///
/// - **Bounded.** A run spends at most ``Budget/messagesPerAccount`` messages
///   per account, in chunks of ``Budget/chunkSize``, with
///   ``Budget/maximumChunksPerAccount`` as a hard stop that holds even if the
///   candidate source misbehaves.
/// - **Cancellable.** ``cancel()`` and task cancellation are both checked at
///   every chunk boundary, because `BGAppRefreshTask`'s expiration handler
///   gives a few seconds' notice and a prefetch that ignores it gets the app's
///   background time revoked.
/// - **Never a busy loop.** A source that keeps returning ids the run has
///   already fetched stops that account immediately, and a run refuses to
///   start again inside ``Budget/minimumInterval``. Without the first guard, a
///   message the server has no body for would be re-requested forever; without
///   the second, two background triggers arriving together would double the
///   load.
/// - **Gives up on failure.** The first error on an account ends that account
///   for the run. A server that is refusing requests is not helped by more of
///   them.
///
/// Foreground paths must not call this. Pull-to-refresh and the visible sync
/// are already competing for the same worker; prefetch belongs to the periodic
/// background refresh and the push handler, exactly as Android's
/// `BodyPrefetcher` does.
public actor BodyPrefetcher {
    /// The limits a run works inside.
    ///
    /// A struct rather than constants so tests can pin the *policy* — that a
    /// run stops — without waiting for real budgets and real delays to elapse.
    public struct Budget: Sendable, Equatable {
        /// Per account, per run. Fifty messages is roughly two days of a busy
        /// mailbox: enough that a commute has something to read, small enough
        /// that a first run on a five-account server is not a thousand bodies.
        public var messagesPerAccount: Int
        /// Twenty, against the hundred delta sync uses. Bodies are large, and
        /// a hundred HTML bodies in one response is where a Pi's PHP memory
        /// limit ends the request with nothing returned at all.
        public var chunkSize: Int
        /// A ceiling on round trips regardless of what the candidate source
        /// says. If the source is wrong — returning the same ids, or more
        /// than asked for — this is the number that still terminates the loop.
        public var maximumChunksPerAccount: Int
        /// Breathing room between chunks. The point is not politeness: a
        /// back-to-back series of body fetches occupies the single worker pool
        /// for the whole run, and anything else the user does meanwhile queues
        /// behind it.
        public var pauseBetweenChunks: Duration
        /// The soonest a second run may start. Two background triggers landing
        /// together — a push and the periodic refresh — is the normal case,
        /// not the exceptional one.
        public var minimumInterval: Duration

        public init(
            messagesPerAccount: Int = 50,
            chunkSize: Int = 20,
            maximumChunksPerAccount: Int = 5,
            pauseBetweenChunks: Duration = .milliseconds(250),
            minimumInterval: Duration = .seconds(15 * 60)
        ) {
            self.messagesPerAccount = messagesPerAccount
            self.chunkSize = chunkSize
            self.maximumChunksPerAccount = maximumChunksPerAccount
            self.pauseBetweenChunks = pauseBetweenChunks
            self.minimumInterval = minimumInterval
        }
    }

    /// Why an account's prefetch ended.
    ///
    /// Reported rather than logged so a test can assert *which* brake stopped
    /// the run. "It stopped" is true of a crash as well.
    public enum Stop: Sendable, Equatable {
        /// The whole per-account budget was spent. The only outcome that means
        /// there is probably more worth fetching next time.
        case budgetSpent
        /// The source ran out of messages without a body.
        case nothingLeft
        /// The source repeated itself, so continuing would re-fetch the same
        /// messages forever.
        case repeatedCandidates
        /// ``cancel()`` was called, or the enclosing task was cancelled.
        case cancelled
        /// The server said no. That account is done for this run.
        case failed
    }

    public struct Report: Sendable, Equatable {
        /// Message ids handed to the hydrator, summed across accounts.
        public var fetched: Int = 0
        /// Round trips made, so a test can prove the chunking is real and a
        /// log line can say what a run cost.
        public var requests: Int = 0
        /// Why each account stopped, keyed by account key.
        public var stops: [String: Stop] = [:]
        /// True when the run was declined outright for being too soon after
        /// the last one, or because one was already in flight.
        public var wasDeclined = false
    }

    /// Which messages still need a body, newest first.
    ///
    /// Injected rather than read from ``SyncStore`` directly because the query
    /// this needs — "messages in this account with no stored body, newest
    /// first, limited" — does not exist on the store yet, and `SyncStore.swift`
    /// is owned elsewhere. Keeping it a parameter also means the bounding and
    /// cancellation policy above is testable without a database.
    public typealias Candidates =
        @Sendable (
            _ accountKey: String, _ limit: Int
        ) async throws -> [String]

    /// Fetches those messages' bodies and stores them.
    ///
    /// - Returns: How many were actually written. A message the server has no
    ///   body for must still be recorded, or it stays a candidate forever and
    ///   consumes the budget on every run for the rest of the account's life.
    public typealias Hydrate =
        @Sendable (
            _ account: AccountSnapshot, _ emailIDs: [String]
        ) async throws -> Int

    private let candidates: Candidates
    private let hydrate: Hydrate
    private let onProgress: Progress?
    private let budget: Budget
    private let logger = Logger(subsystem: "de.plmail", category: "prefetch")

    /// When the next run is allowed to start.
    private var nextRunAllowedAt: Date = .distantPast
    /// Whether a run is in flight. An actor does not prevent this: `run` is
    /// full of awaits, and reentrancy means a second caller walks straight in.
    private var isRunning = false
    /// Set by ``cancel()``. Separate from `Task.isCancelled` because the
    /// background-task expiration handler is not necessarily on the task that
    /// started the run.
    private var isCancelled = false

    /// Told after each chunk lands: how many bodies this run has fetched, and
    /// how many it still means to.
    ///
    /// Exists so the interface can say that background work is happening.
    /// Prefetch is invisible by design — nothing on screen waits for it — and
    /// invisible work that makes a server slow is work nobody can account for.
    public typealias Progress = @Sendable (_ fetched: Int, _ remaining: Int) -> Void

    public init(
        budget: Budget = Budget(),
        candidates: @escaping Candidates,
        hydrate: @escaping Hydrate,
        onProgress: Progress? = nil
    ) {
        self.onProgress = onProgress
        self.budget = budget
        self.candidates = candidates
        self.hydrate = hydrate
    }

    /// Stops the current run at the next chunk boundary.
    ///
    /// Not immediate on purpose: abandoning a response mid-flight wastes the
    /// work the server already did. The next boundary is at most one chunk
    /// away, which is well inside `BGAppRefreshTask`'s expiration warning.
    public func cancel() {
        isCancelled = true
    }

    /// Prefetches bodies for every account, newest first.
    ///
    /// - Parameters:
    ///   - accounts: Every account to prefetch for. Each gets its own
    ///     budget rather than a share of one, so a chatty mailbox cannot
    ///     starve the others.
    ///   - now: Injected so a test can move time without sleeping.
    /// - Returns: What was fetched and why each account stopped. Never throws:
    ///   a failed prefetch is invisible by design — nothing on screen depends
    ///   on it, and an error surfaced to the user for mail they have not asked
    ///   to read yet would be noise.
    @discardableResult
    public func run(accounts: [AccountSnapshot], now: Date = .now) async -> Report {
        guard isRunning == false, now >= nextRunAllowedAt else {
            logger.debug("Prefetch declined: too soon, or one is already running.")
            return Report(wasDeclined: true)
        }

        isRunning = true
        isCancelled = false
        nextRunAllowedAt = now.addingTimeInterval(
            Double(budget.minimumInterval.components.seconds))

        defer { isRunning = false }

        var report = Report()

        for account in accounts {
            guard shouldContinue else {
                report.stops[account.accountKey] = .cancelled
                continue
            }

            await prefetch(account, into: &report)
        }

        logger.info(
            "Prefetched \(report.fetched, privacy: .public) bodies in \(report.requests, privacy: .public) requests."
        )

        return report
    }

    /// One account, inside its own budget.
    private func prefetch(_ account: AccountSnapshot, into report: inout Report) async {
        var remaining = budget.messagesPerAccount
        var chunks = 0
        // Every id this run has already handed to the hydrator. The guard
        // against a source that cannot tell "fetched" from "still needed" —
        // without it a message the server has no body for is requested on
        // every chunk until the budget runs out, every single run.
        var attempted: Set<String> = []

        while remaining > 0, chunks < budget.maximumChunksPerAccount {
            guard shouldContinue else {
                report.stops[account.accountKey] = .cancelled
                return
            }

            let wanted = min(budget.chunkSize, remaining)
            let ids: [String]

            do {
                ids = try await candidates(account.accountKey, wanted)
            } catch {
                logger.error("Prefetch candidates failed: \(error, privacy: .public)")
                report.stops[account.accountKey] = .failed
                return
            }

            guard ids.isEmpty == false else {
                report.stops[account.accountKey] = .nothingLeft
                return
            }

            let fresh = ids.filter { attempted.contains($0) == false }

            guard fresh.isEmpty == false else {
                report.stops[account.accountKey] = .repeatedCandidates
                return
            }

            attempted.formUnion(fresh)

            do {
                _ = try await hydrate(account, fresh)
            } catch {
                logger.error("Prefetch fetch failed: \(error, privacy: .public)")
                report.stops[account.accountKey] = .failed
                return
            }

            report.fetched += fresh.count
            report.requests += 1
            remaining -= fresh.count
            chunks += 1

            onProgress?(report.fetched, remaining)

            if remaining > 0, budget.pauseBetweenChunks > .zero {
                try? await Task.sleep(for: budget.pauseBetweenChunks)
            }
        }

        report.stops[account.accountKey] = .budgetSpent
    }

    /// Both cancellation signals in one place, so no loop can check only one.
    private var shouldContinue: Bool {
        isCancelled == false && Task.isCancelled == false
    }
}
