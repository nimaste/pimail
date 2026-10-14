import Foundation
import JMAPKit
import Testing

@testable import PLMailCore

/// The queue is a shape only in this wave — nothing enqueues or drains yet —
/// so these tests pin the two properties the draining work will depend on and
/// cannot add later: it survives the process, and it comes back in the order it
/// went in.
///
/// Both are why it is here rather than in the SwiftData store: the store is a
/// disposable cache that any open failure deletes, and a conversation archived
/// on a train exists nowhere else until it is sent.
@Suite("Action queue")
struct ActionQueueTests {
    /// Its own server id per test, so the on-disk directories cannot collide —
    /// this is deliberately real files, not a fake.
    private func makeQueue() -> ActionQueue {
        ActionQueue(serverID: "test-\(UUID().uuidString)")
    }

    private func mutation(_ kind: PendingMutation.Kind, thread: String = "t1") -> PendingMutation {
        PendingMutation(
            accountKey: "srv/1",
            accountID: AccountID("1"),
            threadID: thread,
            emailIDs: [EmailID("e1")],
            kind: kind
        )
    }

    @Test("a queued action survives being reloaded from disk")
    func roundTrip() async throws {
        let queue = makeQueue()
        let queued = try await queue.enqueue(mutation(.archive))

        let reloaded = await queue.pending()

        #expect(reloaded.count == 1)
        #expect(reloaded.first?.id == queued.id)
        #expect(reloaded.first?.kind == .archive)
    }

    /// Star-then-unstar and archive-then-move do not commute, so a queue that
    /// replayed by wall clock alone would occasionally invert a pair enqueued in
    /// the same millisecond and leave the server in a state nobody asked for.
    @Test("actions come back in the order they were taken")
    func orderIsPreserved() async throws {
        let queue = makeQueue()

        try await queue.enqueue(mutation(.setFlagged(true)))
        try await queue.enqueue(mutation(.setFlagged(false)))
        try await queue.enqueue(mutation(.archive))

        let kinds = await queue.pending().map(\.kind)

        #expect(kinds == [.setFlagged(true), .setFlagged(false), .archive])
    }

    /// Read before anything rewrites feed rows from the server. Without it a
    /// sync puts back on screen the conversation the user archived a minute
    /// ago, and the gesture looks like it was ignored.
    @Test("the queue can say which conversations it has an opinion about")
    func pendingTargets() async throws {
        let queue = makeQueue()

        try await queue.enqueue(mutation(.archive, thread: "t1"))
        try await queue.enqueue(mutation(.trash, thread: "t2"))

        #expect(await queue.pendingTargets() == ["srv/1#t1", "srv/1#t2"])
    }

    /// An account that has been disconnected can never accept its backlog, and
    /// the drain stops at the first failure — so leaving it queued would stall
    /// every healthy account behind it.
    @Test("dropping one account's backlog leaves the others alone")
    func removeAllForAccount() async throws {
        let queue = makeQueue()

        try await queue.enqueue(mutation(.archive))

        var other = mutation(.archive, thread: "t9")
        other.accountKey = "srv/2"
        try await queue.enqueue(other)

        await queue.removeAll(forAccountKey: "srv/1")

        #expect(await queue.pending().map(\.accountKey) == ["srv/2"])
    }
}
