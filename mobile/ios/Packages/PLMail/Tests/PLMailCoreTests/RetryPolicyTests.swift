import Foundation
import JMAPKit
import Testing

@testable import PLMailCore

/// Retry behaviour is where a client stops being a guest on someone's hardware
/// and starts being a problem. These pin the rules that keep it a guest.
@Suite("Retry and circuit breaking")
struct RetryPolicyTests {
    private let policy = RetryPolicy()

    /// A revoked credential and a malformed request are both deterministic.
    /// Retrying either is pure load with no possibility of a different answer,
    /// and against a home server that matters.
    @Test("only transport failures and 5xx are retried")
    func retryable() {
        #expect(policy.shouldRetry(after: JMAPError.unreachable(host: "nas", code: .timedOut)))
        #expect(policy.shouldRetry(after: JMAPError.unexpectedStatus(code: 503)))

        #expect(policy.shouldRetry(after: JMAPError.notAuthenticated(detail: nil)) == false)
        #expect(
            policy.shouldRetry(
                after: JMAPError.methodFailed(
                    .unsupportedFilter, description: nil, callID: CallID(rawValue: "c0"))
            ) == false
        )
        #expect(
            policy.shouldRetry(after: JMAPError.requestFailed(type: "notJSON", detail: nil))
                == false
        )
    }

    /// Full jitter, not fixed backoff: several accounts that failed together
    /// must not retry together forever.
    @Test("backoff grows, stays under the cap, and is jittered")
    func backoff() {
        let first = (0..<40).map { _ in policy.delay(forAttempt: 1) }
        let later = (0..<40).map { _ in policy.delay(forAttempt: 8) }

        #expect(first.allSatisfy { $0 <= policy.base })
        #expect(later.allSatisfy { $0 <= policy.cap })
        #expect(Set(first).count > 1, "a fixed delay would synchronise every client")
        #expect(later.max() ?? .zero > first.max() ?? .zero)
    }

    @Test("the circuit opens after repeated transport failures")
    func opensOnFailures() async {
        let breaker = CircuitBreaker()

        for _ in 0..<5 {
            await breaker.recordFailure(JMAPError.unreachable(host: "nas", code: .timedOut))
        }

        #expect(await breaker.isOpen)
    }

    /// A rejected app password is not the server being down. Counting it would
    /// make the app go quiet when what it should do is say the credential
    /// needs replacing.
    @Test("an auth failure never opens the circuit")
    func authDoesNotOpen() async {
        let breaker = CircuitBreaker()

        for _ in 0..<20 {
            await breaker.recordFailure(JMAPError.notAuthenticated(detail: nil))
        }

        #expect(await breaker.isOpen == false)
    }

    @Test("one success closes it again")
    func successCloses() async {
        let breaker = CircuitBreaker()

        for _ in 0..<5 {
            await breaker.recordFailure(JMAPError.unreachable(host: "nas", code: .timedOut))
        }
        await breaker.recordSuccess()

        #expect(await breaker.isOpen == false)
    }

    /// Reachability changing, or the user pulling to refresh. Time passing is
    /// not evidence that anything came back.
    @Test("an open circuit reopens only on an explicit signal")
    func explicitReopen() async {
        let breaker = CircuitBreaker()

        for _ in 0..<5 {
            await breaker.recordFailure(JMAPError.unreachable(host: "nas", code: .timedOut))
        }
        #expect(await breaker.isOpen)

        await breaker.allowRetry()
        #expect(await breaker.isOpen == false)
    }

    /// An open circuit must refuse work rather than let it through slowly —
    /// the point is to stop asking entirely.
    @Test("an open circuit refuses without attempting")
    func openRefuses() async {
        let breaker = CircuitBreaker()

        for _ in 0..<5 {
            await breaker.recordFailure(JMAPError.unreachable(host: "nas", code: .timedOut))
        }

        let attempted = Attempted()

        await #expect(throws: JMAPError.self) {
            try await breaker.run { await attempted.record() }
        }
        #expect(await attempted.count == 0)
    }

    @Test("a non-retryable error is not retried even with attempts left")
    func noRetryOnAuth() async {
        let breaker = CircuitBreaker()
        let attempted = Attempted()

        await #expect(throws: JMAPError.self) {
            try await breaker.run(attempts: 5) {
                await attempted.record()
                throw JMAPError.notAuthenticated(detail: nil)
            }
        }

        #expect(await attempted.count == 1)
    }
}

private actor Attempted {
    private(set) var count = 0

    func record() { count += 1 }
}
