import Foundation
import JMAPKit
import Testing

@testable import PLMailCore

/// Draining the offline action queue.
///
/// Three properties carry the whole feature, and each of them has an obvious
/// wrong implementation that looks right in the happy case: a refusal must not
/// be kept (or the client replays it against a server that will go on saying
/// no, forever), order must survive a relaunch (star-then-unstar do not
/// commute), and the drain must stop the moment the network goes away again
/// rather than walking the rest of the queue into the same failure.
@Suite("Action drain")
struct ActionDrainTests {
    /// Its own server id per test, so the on-disk directories cannot collide —
    /// this is deliberately real files, not a fake.
    private func makeQueue() -> ActionQueue {
        ActionQueue(serverID: "drain-\(UUID().uuidString)")
    }

    private func mutation(
        _ kind: PendingMutation.Kind, thread: String = "t1"
    ) -> PendingMutation {
        PendingMutation(
            accountKey: "srv/1",
            accountID: AccountID("1"),
            threadID: thread,
            emailIDs: [EmailID("e1")],
            kind: kind
        )
    }

    // MARK: - What is queue-worthy

    /// The distinction the whole feature turns on. A server that has considered
    /// the change and said no will say no again, so keeping it is a loop that
    /// terminates never — and the row has to go back on screen instead.
    @Test(
        "a server refusal is not queue-worthy",
        arguments: [
            JMAPError.methodFailed(
                .invalidProperties, description: nil, callID: CallID(rawValue: "c0")),
            JMAPError.methodFailed(.forbidden, description: nil, callID: CallID(rawValue: "c0")),
            JMAPError.methodFailed(
                .accountReadOnly, description: nil, callID: CallID(rawValue: "c0")),
            JMAPError.notAuthenticated(detail: nil),
            JMAPError.untrustedCertificate(host: "nas.local", fingerprint: "aa"),
            JMAPError.requestFailed(type: "notJSON", detail: nil),
        ])
    func refusalsAreNotQueued(error: JMAPError) {
        #expect(ActionFailure.classify(error) == .refusal)
    }

    /// This device is right and the server has not caught up. Discarding these
    /// is what loses the conversation someone archived on a train.
    @Test(
        "a transport failure is queue-worthy",
        arguments: [
            JMAPError.unreachable(host: "nas.local", code: .cannotConnectToHost),
            JMAPError.unexpectedStatus(code: 502),
            JMAPError.malformedResponse("truncated"),
        ])
    func transportFailuresAreQueued(error: JMAPError) {
        #expect(ActionFailure.classify(error) == .transport)
    }

    @Test("a URL error and a cancellation are both transport failures")
    func urlErrorsAreQueued() {
        #expect(ActionFailure.classify(URLError(.timedOut)) == .transport)
        #expect(ActionFailure.classify(CancellationError()) == .transport)
    }

    /// Queueing is the destructive default — it leaves the cache disagreeing
    /// with the server until something drains — so anything unrecognised goes
    /// back on screen rather than into the queue.
    @Test("an error this cannot name is treated as a refusal")
    func unknownErrorsAreRefusals() {
        struct Mystery: Error {}

        #expect(ActionFailure.classify(Mystery()) == .refusal)
    }

    // MARK: - Draining

    @Test("everything that is accepted leaves the queue")
    func drainsAccepted() async throws {
        let queue = makeQueue()
        let drain = ActionDrain(queue: queue)

        try await queue.enqueue(mutation(.archive, thread: "t1"))
        try await queue.enqueue(mutation(.archive, thread: "t2"))

        let summary = await drain.drain { _ in .sent }

        #expect(summary.sent == 2)
        #expect(summary.remaining == 0)
        #expect(await queue.pending().isEmpty)
    }

    /// The other half of the classification rule, at the queue rather than at
    /// the error: a refusal that reached the server is dropped, so the queue can
    /// always empty. Keeping it would stall every action behind it as well.
    @Test("a refused action is dropped rather than retried forever")
    func refusalIsDropped() async throws {
        let queue = makeQueue()
        let drain = ActionDrain(queue: queue)

        try await queue.enqueue(mutation(.archive))

        let summary = await drain.drain { _ in .refused("invalidProperties") }

        #expect(summary.refused == 1)
        #expect(await queue.pending().isEmpty)
    }

    /// Star-then-unstar and archive-then-move do not commute. Skipping past a
    /// stuck mutation to send the one behind it leaves the server in a state
    /// nobody asked for.
    @Test("the drain stops at the first transport failure and keeps the order")
    func stopsAtFirstFailure() async throws {
        let queue = makeQueue()
        let drain = ActionDrain(queue: queue)

        try await queue.enqueue(mutation(.setFlagged(true), thread: "t1"))
        try await queue.enqueue(mutation(.setFlagged(false), thread: "t2"))
        try await queue.enqueue(mutation(.archive, thread: "t3"))

        let attempted = Attempts()

        let summary = await drain.drain { mutation in
            await attempted.record(mutation.threadID)

            return mutation.threadID == "t2" ? .unreachable : .sent
        }

        #expect(summary.stoppedEarly)
        #expect(summary.sent == 1)
        #expect(await attempted.threadIDs == ["t1", "t2"])
        // The failing item is still at the head, with the one behind it
        // untouched and still behind it.
        #expect(await queue.pending().map(\.threadID) == ["t2", "t3"])
    }

    /// A drain runs from a background refresh with an expiration handler.
    /// Stopping mid-queue has to leave the remainder on disk.
    @Test("a failed item records the attempt rather than losing its place")
    func recordsAttempts() async throws {
        let queue = makeQueue()
        let drain = ActionDrain(queue: queue)

        try await queue.enqueue(mutation(.archive))

        _ = await drain.drain(now: Date(timeIntervalSince1970: 0)) { _ in .unreachable }

        #expect(await queue.pending().first?.attempts == 1)
    }

    /// The audience runs this server on a Raspberry Pi with one worker pool. A
    /// drain that tried again on every foreground and every network flap would
    /// be the aggressive polling the server cannot afford.
    @Test("a second drain immediately after a failure does not touch the server")
    func backsOff() async throws {
        let queue = makeQueue()
        let drain = ActionDrain(queue: queue)

        try await queue.enqueue(mutation(.archive))

        let now = Date(timeIntervalSince1970: 1_700_000_000)

        _ = await drain.drain(now: now) { _ in .unreachable }

        let attempted = Attempts()
        let second = await drain.drain(now: now) { mutation in
            await attempted.record(mutation.threadID)

            return .sent
        }

        #expect(second.wasDeferred)
        #expect(await attempted.threadIDs.isEmpty)

        // The network path changing is evidence worth acting on, unlike the
        // passage of time.
        await drain.allowRetry()

        let third = await drain.drain(now: now) { _ in .sent }

        #expect(third.sent == 1)
    }

    /// The queue is files on disk precisely so a relaunch mid-backlog continues
    /// rather than starts over, and the order it continues in is the order the
    /// user gestured in.
    @Test("order survives the process going away and a fresh queue opening")
    func orderSurvivesRelaunch() async throws {
        let serverID = "relaunch-\(UUID().uuidString)"
        let first = ActionQueue(serverID: serverID)

        try await first.enqueue(mutation(.setFlagged(true), thread: "t1"))
        try await first.enqueue(mutation(.setFlagged(false), thread: "t2"))
        try await first.enqueue(mutation(.archive, thread: "t3"))

        // A second actor over the same directory is exactly what a relaunch is.
        let reopened = ActionQueue(serverID: serverID)
        let drain = ActionDrain(queue: reopened)
        let attempted = Attempts()

        let summary = await drain.drain { mutation in
            await attempted.record(mutation.threadID)

            return .sent
        }

        #expect(summary.sent == 3)
        #expect(await attempted.threadIDs == ["t1", "t2", "t3"])
    }

    /// Records what the drain actually sent, in order. An actor rather than a
    /// captured `var` because the closure is `@Sendable`.
    private actor Attempts {
        private(set) var threadIDs: [String] = []

        func record(_ threadID: String) {
            threadIDs.append(threadID)
        }
    }
}
