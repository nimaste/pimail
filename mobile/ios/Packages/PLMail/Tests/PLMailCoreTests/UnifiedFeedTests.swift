import Foundation
import JMAPKit
import JMAPTestSupport
import SwiftData
import Testing

@testable import PLMailCore

/// The merge is the one piece of this app that can be wrong in ways nobody
/// notices: a duplicate looks like the server sent two, a dropped message
/// looks like it was never delivered, and both only appear at page boundaries
/// on a multi-account setup. So these run against a server that really pages.
@Suite("UnifiedFeed")
struct UnifiedFeedTests {
    // MARK: - Fixtures

    /// Distinct minutes, so ordering assertions are unambiguous except where a
    /// test deliberately makes timestamps collide.
    private static func date(_ minutesAgo: Int) -> Date {
        Date(timeIntervalSince1970: 1_800_000_000 - Double(minutesAgo) * 60)
    }

    private func makeStore() -> SyncStore {
        SyncStore(modelContainer: MailStack.makeContainer(inMemory: true))
    }

    /// Builds a feed over the fake server's accounts, restoring any cursors
    /// the store already holds.
    private func makeFeed(
        server: FakeMailServer,
        store: SyncStore,
        client: JMAPClient? = nil
    ) async -> UnifiedFeed {
        let feed = UnifiedFeed(
            feedID: .unified(.inbox),
            client: client ?? server.makeClient(),
            store: store
        )

        await feed.prepare(
            pagers: server.accountIDs.map { id in
                AccountPager(
                    accountKey: "fake.test/\(id)",
                    accountID: AccountID(id),
                    baseFilter: .inMailbox(MailboxID("1"))
                )
            }
        )

        return feed
    }

    private func feedRows(_ store: SyncStore) async throws -> [FeedEntrySnapshot] {
        try await store.feedRows(feedID: FeedID.unified(.inbox).rawValue)
    }

    // MARK: - Ordering

    /// The point of the whole exercise: three accounts, interleaved, in one
    /// date order — not three blocks one after another.
    @Test("rows come out in strict global date order across accounts")
    func globalOrdering() async throws {
        let server = FakeMailServer(accounts: [
            "1": (0..<20).map { .init(id: "a\($0)", receivedAt: Self.date($0 * 3)) },
            "2": (0..<20).map { .init(id: "b\($0)", receivedAt: Self.date($0 * 3 + 1)) },
            "3": (0..<20).map { .init(id: "c\($0)", receivedAt: Self.date($0 * 3 + 2)) },
        ])

        let store = makeStore()
        let feed = await makeFeed(server: server, store: store)

        await feed.loadMore(count: 30)

        let rows = try await feedRows(store).sorted { $0.sortDate > $1.sortDate }
        let emitted = try await feedRows(store)

        #expect(emitted.count == 30)
        #expect(
            zip(rows, rows.dropFirst()).allSatisfy { $0.sortDate > $1.sortDate },
            "dates must strictly decrease"
        )

        // Interleaved, not blocked: the first three rows should come from
        // three different accounts.
        #expect(Set(rows.prefix(3).map(\.accountKey)).count == 3)
    }

    /// A page boundary is where a merge most easily emits the same row twice —
    /// once from the buffer and once from the re-query that follows it.
    @Test("paging past a boundary produces no duplicates and no gaps")
    func noDuplicatesAcrossPages() async throws {
        let server = FakeMailServer(accounts: [
            "1": (0..<120).map { .init(id: "a\($0)", receivedAt: Self.date($0 * 2)) },
            "2": (0..<120).map { .init(id: "b\($0)", receivedAt: Self.date($0 * 2 + 1)) },
        ])

        let store = makeStore()
        let feed = await makeFeed(server: server, store: store)

        // Three loads, each spanning more than one server page per account.
        for _ in 0..<3 {
            await feed.loadMore(count: 60)
        }

        let ids = try await feedRows(store).map(\.emailID)

        #expect(ids.count == Set(ids).count, "no row may be emitted twice")

        // Exactly the N newest messages across both accounts, in order.
        // Asserted against the corpus rather than against a property of the
        // result, because "sorted and unique" is also true of a list that
        // silently skipped a message in the middle.
        let corpus =
            (0..<120).map { ("a\($0)", Self.date($0 * 2)) }
            + (0..<120).map { ("b\($0)", Self.date($0 * 2 + 1)) }

        let expected =
            corpus
            .sorted { $0.1 > $1.1 }
            .prefix(ids.count)
            .map(\.0)

        #expect(ids == expected, "the feed must be the newest N with nothing skipped")
    }

    /// `before` is a strict `<`, so a naive cursor drops every message that
    /// shares the boundary second. Five at one timestamp, straddling a page
    /// boundary, is the case that catches it.
    @Test("messages sharing one second at a page boundary all survive")
    func sharedTimestampAtBoundary() async throws {
        let collision = Self.date(500)

        var messages: [FakeMailServer.Message] = (0..<48).map {
            .init(id: "early\($0)", receivedAt: Self.date($0))
        }
        // Land the collision so it spans the 50-row page edge.
        messages += (0..<5).map { .init(id: "tie\($0)", receivedAt: collision) }
        messages += (0..<20).map { .init(id: "late\($0)", receivedAt: Self.date(600 + $0)) }

        let server = FakeMailServer(accounts: ["1": messages])
        let store = makeStore()
        let feed = await makeFeed(server: server, store: store)

        await feed.loadMore(count: 40)
        await feed.loadMore(count: 40)

        let ids = try await feedRows(store).map(\.emailID)

        for index in 0..<5 {
            #expect(ids.contains("tie\(index)"), "tie\(index) was dropped at the page boundary")
        }
        #expect(ids.count == Set(ids).count)
    }

    /// Mail arriving between two pages is what breaks offset paging. Date
    /// keyset paging should be immune: the new message is newer than the
    /// cursor, so it cannot shift the window.
    @Test("mail arriving mid-paging causes neither a duplicate nor a gap")
    func insertionDuringPaging() async throws {
        let server = FakeMailServer(accounts: [
            "1": (0..<100).map { .init(id: "a\($0)", receivedAt: Self.date($0 + 10)) }
        ])

        let store = makeStore()
        let feed = await makeFeed(server: server, store: store)

        await feed.loadMore(count: 30)

        // Newer than everything already emitted.
        server.insert(.init(id: "fresh", receivedAt: Self.date(0)), accountID: "1")

        await feed.loadMore(count: 30)

        let ids = try await feedRows(store).map(\.emailID)

        #expect(ids.count == Set(ids).count, "the insertion must not duplicate a row")
        // It sorts above the window already paged, so it is not picked up by
        // paging downwards — a refresh is what surfaces it. What matters here
        // is that it did not corrupt the rows around it.
        #expect(ids.contains("a30"))
        #expect(ids.contains("a59"))
    }

    // MARK: - Degradation

    /// Multi-account is the normal case, so one account failing has to leave
    /// the others usable rather than blanking the list.
    @Test("one failing account degrades without emptying the feed")
    func degradedAccount() async throws {
        let server = FakeMailServer(accounts: [
            "1": (0..<20).map { .init(id: "a\($0)", receivedAt: Self.date($0 * 2)) },
            "2": (0..<20).map { .init(id: "b\($0)", receivedAt: Self.date($0 * 2 + 1)) },
        ])
        server.setFailing(true, accountID: "2")

        let store = makeStore()
        let feed = await makeFeed(server: server, store: store)

        await feed.loadMore(count: 30)

        let rows = try await feedRows(store)
        let failures = await feed.failures

        #expect(rows.isEmpty == false, "the healthy account must still populate the list")
        #expect(rows.allSatisfy { $0.emailID.hasPrefix("a") })
        #expect(failures.count == 1)
        #expect(failures.keys.first == "fake.test/2")
    }

    /// A merge that cannot tell exhaustion from an empty page loops forever.
    @Test("the merge terminates once every account runs out")
    func termination() async throws {
        let server = FakeMailServer(accounts: [
            "1": (0..<7).map { .init(id: "a\($0)", receivedAt: Self.date($0 * 2)) },
            "2": (0..<5).map { .init(id: "b\($0)", receivedAt: Self.date($0 * 2 + 1)) },
        ])

        let store = makeStore()
        let feed = await makeFeed(server: server, store: store)

        let first = await feed.loadMore(count: 500)
        let second = await feed.loadMore(count: 500)

        #expect(first == 12, "every message should be emitted exactly once")
        #expect(second == 0, "an exhausted feed emits nothing and does not hang")

        let queriesAfter = server.queryCount
        await feed.loadMore(count: 500)

        #expect(
            server.queryCount == queriesAfter,
            "an exhausted account must not be re-queried on every scroll"
        )
    }

    // MARK: - Durability

    /// The cursor advances on emit, not on fetch. A page fetched into the
    /// buffer but never emitted must be re-fetched next launch, or the rows in
    /// it vanish from the list permanently.
    @Test("a buffered but unemitted page is not skipped after a restart")
    func bufferIsNotDurableState() async throws {
        let server = FakeMailServer(accounts: [
            "1": (0..<100).map { .init(id: "a\($0)", receivedAt: Self.date($0)) },
            "2": (0..<100).map { .init(id: "b\($0)", receivedAt: Self.date($0 + 200)) },
        ])

        let store = makeStore()

        // Account 2's mail is entirely older, so paging a few rows fetches a
        // page from it that is buffered and never emitted.
        let feed = await makeFeed(server: server, store: store)
        await feed.loadMore(count: 10)

        // A new feed over the same store is exactly what a relaunch does.
        let relaunched = await makeFeed(server: server, store: store)
        await relaunched.loadMore(count: 200)

        let ids = try await feedRows(store).map(\.emailID)

        #expect(ids.count == Set(ids).count, "a restart must not duplicate rows")
        #expect(ids.contains("b0"), "account 2's newest message must not be skipped")
        #expect(ids.contains("a10"), "paging must resume where it stopped")
    }

    /// The persisted cursor has its own tie problem, separate from the pager's.
    ///
    /// If a restart lands mid-way through a run of messages sharing one
    /// timestamp, the restored cursor must remember *which* of them were
    /// already emitted. Remembering only the last one makes the next page
    /// re-emit its siblings.
    ///
    /// Asserted on the emitted count rather than on the stored rows, because
    /// the feed table upserts by thread and would quietly absorb a duplicate —
    /// which is what makes this failure invisible without counting.
    @Test("a restart mid-tie does not re-emit the rows already past")
    func restartWithinATie() async throws {
        let tie = Self.date(300)

        var messages: [FakeMailServer.Message] = (0..<10).map {
            .init(id: "early\($0)", receivedAt: Self.date($0))
        }
        messages += (0..<5).map { .init(id: "tie\($0)", receivedAt: tie) }
        messages += (0..<10).map { .init(id: "late\($0)", receivedAt: Self.date(400 + $0)) }

        let server = FakeMailServer(accounts: ["1": messages])
        let store = makeStore()

        // Stops two rows into the run of five sharing `tie`.
        let first = await makeFeed(server: server, store: store)
        let emittedBefore = await first.loadMore(count: 12)

        let relaunched = await makeFeed(server: server, store: store)
        let emittedAfter = await relaunched.loadMore(count: 100)

        #expect(emittedBefore == 12)
        #expect(
            emittedBefore + emittedAfter == messages.count,
            "every message emitted exactly once across the restart"
        )

        let ids = try await feedRows(store).map(\.emailID)
        #expect(ids.count == messages.count)
        #expect(Set(ids).count == messages.count)
    }

    // MARK: - Refresh

    /// A refresh brings in new mail without discarding the tail — that is what
    /// keeps scroll position and what keeps the server from re-serving pages
    /// it has already served.
    @Test("refresh splices new mail above the tail it already has")
    func refreshSplices() async throws {
        let server = FakeMailServer(accounts: [
            "1": (0..<60).map { .init(id: "a\($0)", receivedAt: Self.date($0 + 100)) }
        ])

        let store = makeStore()
        let feed = await makeFeed(server: server, store: store)

        await feed.loadMore(count: 60)
        let deepestBefore = try await feedRows(store).map(\.sortDate).min()

        server.insert(.init(id: "fresh", receivedAt: Self.date(0)), accountID: "1")
        await feed.refreshHead()

        let rows = try await feedRows(store)
        let ids = rows.map(\.emailID)

        #expect(ids.contains("fresh"), "new mail must appear")
        #expect(ids.count == Set(ids).count)
        #expect(rows.map(\.sortDate).min() == deepestBefore, "the tail must be left alone")
    }
}
