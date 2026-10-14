import Foundation
import JMAPKit

/// When to try again, and when to stop.
///
/// The server this talks to is frequently a NAS or a Raspberry Pi behind a
/// domestic uplink, with a small worker pool. A client that retries eagerly
/// does not merely waste its own battery — it occupies the workers and takes
/// the server down for the browser tab as well. So the default is to wait, and
/// to stop entirely once it is clear nobody is answering.
public struct RetryPolicy: Sendable {
    /// First wait, doubling from there.
    public var base: Duration = .seconds(2)
    /// Ceiling. Beyond this, waiting longer gains nothing over waiting for the
    /// user to come back.
    public var cap: Duration = .seconds(300)
    /// Consecutive failures before the circuit opens.
    public var failureThreshold = 5

    public init() {}

    /// Whether this error is worth trying again at all.
    ///
    /// Transport failures and 5xx only. A rejected credential and a malformed
    /// request are both deterministic: retrying them is pure load with no
    /// possibility of a different answer.
    public func shouldRetry(after error: any Error) -> Bool {
        guard let error = error as? JMAPError else { return false }

        return error.isRetryable
    }

    /// How long to wait before attempt number `attempt` (1-based).
    ///
    /// Exponential with **full jitter** — the delay is a random point in
    /// `0..<backoff` rather than the backoff itself. Without it, several
    /// accounts that failed together retry together forever, which is the
    /// thundering herd this is meant to avoid.
    public func delay(forAttempt attempt: Int) -> Duration {
        let exponent = max(0, attempt - 1)
        let scaled = base * pow(2, Double(exponent))
        let bounded = min(scaled, cap)

        return bounded * Double.random(in: 0...1)
    }
}

/// Tracks whether a server is worth talking to right now.
///
/// One breaker per server rather than per account: when a NAS is off, every
/// account on it fails, and five accounts should not mean five times the
/// retries.
public actor CircuitBreaker {
    public enum State: Equatable, Sendable {
        case closed
        /// Failing. Nothing is attempted until something suggests the server
        /// is back — reachability changing, or the user asking directly.
        case open(since: Date, consecutiveFailures: Int)
    }

    public private(set) var state: State = .closed

    private let policy: RetryPolicy
    private var consecutiveFailures = 0

    public init(policy: RetryPolicy = RetryPolicy()) {
        self.policy = policy
    }

    public var isOpen: Bool {
        if case .open = state { return true }
        return false
    }

    public func recordSuccess() {
        consecutiveFailures = 0
        state = .closed
    }

    public func recordFailure(_ error: any Error) {
        // A rejected credential is not the server being down, and it must not
        // count towards opening the circuit — the remedy is a new app
        // password, and the UI says so rather than silently going quiet.
        guard policy.shouldRetry(after: error) else { return }

        consecutiveFailures += 1

        if consecutiveFailures >= policy.failureThreshold {
            state = .open(since: .now, consecutiveFailures: consecutiveFailures)
        }
    }

    /// Reopens the circuit for one attempt.
    ///
    /// Called when the network path changes or the user pulls to refresh —
    /// both are evidence worth acting on, unlike the passage of time.
    public func allowRetry() {
        state = .closed
    }

    /// Runs `work`, retrying while the policy allows.
    ///
    /// - Parameters:
    ///   - attempts: The ceiling on tries, including the first.
    ///   - work: The operation to attempt.
    /// - Returns: Whatever `work` produced on the attempt that succeeded.
    /// - Throws: The last error, or ``JMAPKit/JMAPError/unreachable(host:code:)``
    ///   without attempting anything when the circuit is already open.
    public func run<T: Sendable>(
        attempts: Int = 3,
        _ work: @Sendable () async throws -> T
    ) async throws -> T {
        guard isOpen == false else {
            throw JMAPError.unreachable(host: "", code: .cannotConnectToHost)
        }

        var lastError: any Error = JMAPError.malformedResponse("No attempt was made.")

        for attempt in 1...max(1, attempts) {
            do {
                let value = try await work()
                recordSuccess()
                return value
            } catch {
                lastError = error
                recordFailure(error)

                guard policy.shouldRetry(after: error), attempt < attempts, isOpen == false else {
                    throw error
                }

                try? await Task.sleep(for: policy.delay(forAttempt: attempt))
            }
        }

        throw lastError
    }
}
