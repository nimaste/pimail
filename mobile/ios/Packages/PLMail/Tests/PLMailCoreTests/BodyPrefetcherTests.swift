import Foundation
import JMAPKit
import Synchronization
import Testing

@testable import PLMailCore

/// Every test here pins a brake rather than a feature. The prefetcher's whole
/// job is to fetch *less* than it could: the server is somebody's Raspberry Pi
/// with one PHP worker pool, and a prefetcher that runs unbounded, ignores
/// cancellation, or re-requests the same message forever is worse than not
/// having one.
@Suite("Body prefetch")
struct BodyPrefetcherTests {
    /// A candidate source that always has more to give.
    ///
    /// Deliberately infinite: nothing here should terminate because the fake
    /// ran out. If a test passes, it passed because the prefetcher stopped
    /// itself.
    private final class Source: Sendable {
        let issued = Mutex<[String]>([])
        let requests = Mutex(0)
        /// When true, the source keeps handing back the *same* ids — the
        /// shape a store takes on when a message has no body to store and
        /// therefore never stops being a candidate.
        let repeats: Bool

        init(repeats: Bool = false) { self.repeats = repeats }

        func candidates(_ accountKey: String, _ limit: Int) -> [String] {
            requests.withLock { $0 += 1 }

            // Numbered from how many have been handed out, not from the
            // request count: chunks are not all the same size, and a fake that
            // reissued ids would trip the prefetcher's repeat guard and make
            // every test pass for the wrong reason.
            let start = issued.withLock(\.count)
            let ids = (0..<limit).map { "\(accountKey)-e\(repeats ? $0 : start + $0)" }

            if repeats == false { issued.withLock { $0.append(contentsOf: ids) } }

            return ids
        }
    }

    private func account(_ key: String = "srv/a") -> AccountSnapshot {
        AccountSnapshot(accountKey: key, accountID: AccountID(key), name: "Mailbox")
    }

    private func budget(
        messagesPerAccount: Int = 50,
        chunkSize: Int = 20,
        maximumChunksPerAccount: Int = 5,
        minimumInterval: Duration = .seconds(900)
    ) -> BodyPrefetcher.Budget {
        BodyPrefetcher.Budget(
            messagesPerAccount: messagesPerAccount,
            chunkSize: chunkSize,
            maximumChunksPerAccount: maximumChunksPerAccount,
            // Zero throughout: the pause is real politeness in the app and
            // dead waiting in a test.
            pauseBetweenChunks: .zero,
            minimumInterval: minimumInterval
        )
    }

    @Test("a run never fetches more than the per-account budget")
    func staysInsideItsBudget() async {
        let source = Source()
        let fetched = Mutex(0)

        let prefetcher = BodyPrefetcher(
            budget: budget(messagesPerAccount: 50, chunkSize: 20),
            candidates: { key, limit in source.candidates(key, limit) },
            hydrate: { _, ids in
                fetched.withLock { $0 += ids.count }
                return ids.count
            }
        )

        let report = await prefetcher.run(accounts: [account()])

        #expect(fetched.withLock { $0 } == 50)
        #expect(report.fetched == 50)
        #expect(report.stops["srv/a"] == .budgetSpent)
    }

    @Test("bodies are asked for in small chunks, not one enormous request")
    func chunksTheRequests() async {
        let source = Source()
        let sizes = Mutex<[Int]>([])

        let prefetcher = BodyPrefetcher(
            budget: budget(messagesPerAccount: 50, chunkSize: 20),
            candidates: { key, limit in source.candidates(key, limit) },
            hydrate: { _, ids in
                sizes.withLock { $0.append(ids.count) }
                return ids.count
            }
        )

        _ = await prefetcher.run(accounts: [account()])

        #expect(sizes.withLock { $0 } == [20, 20, 10])
    }

    @Test("the chunk ceiling stops a run even when the budget cannot")
    func chunkCeilingHolds() async {
        let source = Source()

        let prefetcher = BodyPrefetcher(
            budget: budget(
                messagesPerAccount: 1_000, chunkSize: 10, maximumChunksPerAccount: 3),
            candidates: { key, limit in source.candidates(key, limit) },
            hydrate: { _, ids in ids.count }
        )

        let report = await prefetcher.run(accounts: [account()])

        #expect(report.requests == 3)
        #expect(report.fetched == 30)
    }

    @Test("a source that keeps returning the same messages stops the account")
    func doesNotLoopOnRepeatedCandidates() async {
        let source = Source(repeats: true)

        let prefetcher = BodyPrefetcher(
            budget: budget(messagesPerAccount: 1_000, chunkSize: 10),
            candidates: { key, limit in source.candidates(key, limit) },
            hydrate: { _, ids in ids.count }
        )

        let report = await prefetcher.run(accounts: [account()])

        #expect(report.stops["srv/a"] == .repeatedCandidates)
        #expect(report.fetched == 10)
    }

    @Test("cancelling the enclosing task stops the run at the next chunk")
    func honoursTaskCancellation() async {
        let source = Source()
        let started = Mutex(false)

        let prefetcher = BodyPrefetcher(
            budget: budget(
                messagesPerAccount: 1_000, chunkSize: 10, maximumChunksPerAccount: 100),
            candidates: { key, limit in source.candidates(key, limit) },
            hydrate: { _, ids in
                started.withLock { $0 = true }

                // Stands in for a request in flight when the background task's
                // expiration handler fires. The chunk is allowed to finish;
                // what must not happen is a second one.
                while Task.isCancelled == false { await Task.yield() }

                return ids.count
            }
        )

        let task = Task { await prefetcher.run(accounts: [account()]) }

        while started.withLock({ $0 }) == false { await Task.yield() }

        task.cancel()

        let report = await task.value

        #expect(report.stops["srv/a"] == .cancelled)
        #expect(report.fetched == 10)
    }

    @Test("cancelling mid-run leaves the remaining budget unspent")
    func stopsMidRun() async {
        let source = Source()
        let hydrated = Mutex(0)
        // The prefetcher has to exist before the closure that cancels it can
        // name it, so it arrives through a box. The point of the test is that
        // `cancel()` lands *during* a run, which is the only moment the
        // background task's expiration handler will ever get.
        let box = Mutex<BodyPrefetcher?>(nil)

        let prefetcher = BodyPrefetcher(
            budget: budget(
                messagesPerAccount: 1_000, chunkSize: 10, maximumChunksPerAccount: 100),
            candidates: { key, limit in source.candidates(key, limit) },
            hydrate: { _, ids in
                let total = hydrated.withLock { count -> Int in
                    count += ids.count
                    return count
                }

                if total >= 20 { await box.withLock { $0 }?.cancel() }
                return ids.count
            }
        )

        box.withLock { $0 = prefetcher }

        let report = await prefetcher.run(accounts: [account()])

        #expect(report.stops["srv/a"] == .cancelled)
        #expect(report.fetched == 20)
    }

    @Test("a second run inside the minimum interval is declined outright")
    func refusesToRunAgainTooSoon() async {
        let source = Source()
        let prefetcher = BodyPrefetcher(
            budget: budget(messagesPerAccount: 10, chunkSize: 10),
            candidates: { key, limit in source.candidates(key, limit) },
            hydrate: { _, ids in ids.count }
        )

        let now = Date(timeIntervalSince1970: 1_750_000_000)

        let first = await prefetcher.run(accounts: [account()], now: now)
        let second = await prefetcher.run(
            accounts: [account()], now: now.addingTimeInterval(60))
        let third = await prefetcher.run(
            accounts: [account()], now: now.addingTimeInterval(1_000))

        #expect(first.fetched == 10)
        #expect(second.wasDeclined)
        #expect(second.fetched == 0)
        #expect(third.fetched == 10)
    }

    @Test("the first failure ends that account rather than retrying it")
    func givesUpOnAFailingServer() async {
        let source = Source()
        let attempts = Mutex(0)

        let prefetcher = BodyPrefetcher(
            budget: budget(messagesPerAccount: 100, chunkSize: 10),
            candidates: { key, limit in source.candidates(key, limit) },
            hydrate: { _, _ in
                attempts.withLock { $0 += 1 }
                throw JMAPError.unexpectedStatus(code: 503)
            }
        )

        let report = await prefetcher.run(accounts: [account()])

        #expect(attempts.withLock { $0 } == 1)
        #expect(report.stops["srv/a"] == .failed)
        #expect(report.fetched == 0)
    }

    @Test("running out of candidates ends the account without spending the budget")
    func stopsWhenThereIsNothingLeft() async {
        let prefetcher = BodyPrefetcher(
            budget: budget(messagesPerAccount: 50, chunkSize: 20),
            candidates: { _, _ in [] },
            hydrate: { _, ids in ids.count }
        )

        let report = await prefetcher.run(accounts: [account()])

        #expect(report.stops["srv/a"] == .nothingLeft)
        #expect(report.requests == 0)
    }

    @Test("each account gets its own budget rather than sharing one")
    func budgetIsPerAccount() async {
        let source = Source()
        let prefetcher = BodyPrefetcher(
            budget: budget(messagesPerAccount: 20, chunkSize: 20),
            candidates: { key, limit in source.candidates(key, limit) },
            hydrate: { _, ids in ids.count }
        )

        let report = await prefetcher.run(
            accounts: [account("srv/a"), account("srv/b")])

        #expect(report.fetched == 40)
        #expect(report.stops.count == 2)
    }
}
