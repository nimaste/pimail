import Foundation
import JMAPKit
import JMAPTestSupport
import Testing

@testable import PLMailCore

/// Draining a queue that has something scheduled in it.
///
/// The store here is empty on purpose, so every message the sender actually
/// picks up fails at "this account has no Drafts mailbox" without a request
/// leaving. That failure is the signal: a message that was *tried* carries an
/// attempt and a reason, a message that was skipped carries neither, and the
/// two are what these tests tell apart.
@Suite("Outbox sender")
@MainActor
struct OutboxSenderTests {
    private func makeSender(_ outbox: Outbox) -> OutboxSender {
        OutboxSender(
            outbox: outbox,
            client: JMAPClient(
                discoveryURL: URL(string: "https://nas.local/.well-known/jmap")!,
                credential: .appPassword("plmail_test"),
                transport: MockTransport(body: Data("{}".utf8), statusCode: 500)
            ),
            store: SyncStore(modelContainer: MailStack.makeContainer(inMemory: true))
        )
    }

    private func makeOutbox() -> Outbox {
        Outbox(serverID: "test-\(UUID().uuidString)")
    }

    private func message(subject: String) -> Outbox.PendingMessage {
        Outbox.PendingMessage(
            accountKey: "srv/1",
            accountID: AccountID("1"),
            identityID: IdentityID(rawValue: "3"),
            from: EmailAddress(name: "Me", email: "me@example.com"),
            to: [EmailAddress(name: nil, email: "you@example.com")],
            subject: subject,
            body: "Body"
        )
    }

    private func drainAndSettle(_ sender: OutboxSender) async {
        sender.drain()
        await sender.settle()
    }

    /// The whole feature in one assertion: a drain is not evidence that a
    /// scheduled message is ready to **leave**.
    ///
    /// What changed with server-side scheduling is that a drain now *offers*
    /// the schedule to the server. What must not change is the thing that
    /// matters: the message is still here, still held, and still this device's
    /// until a server says otherwise. The server is unreachable in this suite,
    /// so the offer fails and the fallback is what is left — which is precisely
    /// the case the outbox exists for.
    @Test("A message scheduled for later is offered to the server, never sent from here")
    func offersButDoesNotSend() async throws {
        let outbox = makeOutbox()

        var held = message(subject: "Tomorrow")
        held.queuedAt = Date(timeIntervalSince1970: 1_000)
        held.sendAfter = .now.addingTimeInterval(3_600)

        var now = message(subject: "Now")
        now.queuedAt = Date(timeIntervalSince1970: 2_000)

        try await outbox.enqueue(held)
        try await outbox.enqueue(now)

        await drainAndSettle(makeSender(outbox))

        let stored = await outbox.pending()
        let reloadedHeld = try #require(stored.first { $0.subject == "Tomorrow" })
        let reloadedNow = try #require(stored.first { $0.subject == "Now" })

        // Still ours. No handover was recorded, so nothing on this device
        // believes the server is holding mail that it is not.
        #expect(reloadedHeld.handover == nil)
        #expect(reloadedHeld.isDeviceHeld)
        #expect(reloadedHeld.isDue(at: .now) == false)
        #expect(reloadedHeld.sendAfter != nil, "the schedule survives a failed handover")

        #expect(reloadedNow.attempts == 1)
        #expect(reloadedNow.lastFailure != nil)
    }

    /// A message the server has taken over is never sent from here again.
    ///
    /// The one invariant the whole handover rests on. Written against the
    /// record rather than against a drain, because it has to hold however the
    /// clock moves: a handed-over message that is a day overdue is still not
    /// this device's to send.
    @Test("A handed-over message is never due again, however late it gets")
    func handoverIsFinal() async throws {
        let outbox = makeOutbox()

        var held = message(subject: "Handed over")
        held.sendAfter = .now.addingTimeInterval(60)

        try await outbox.enqueue(held)
        await outbox.recordHandover(
            held.id,
            Outbox.PendingMessage.Handover(
                submissionID: "77", sendAt: .now.addingTimeInterval(60)))

        let stored = try #require(await outbox.pending().first)

        #expect(stored.isDue(at: .now) == false)
        #expect(stored.isDue(at: .now.addingTimeInterval(86_400)) == false)
        #expect(stored.isDeviceHeld == false)

        // And a drain agrees: nothing is sent from here.
        await drainAndSettle(makeSender(outbox))

        let after = try #require(await outbox.pending().first)

        #expect(after.handover?.submissionID == "77")
    }

    /// A queue holding nothing but scheduled mail must not look like one that
    /// is trying to send — no spinner, and nothing leaves.
    @Test("A queue of nothing but scheduled mail does not start sending")
    func nothingDue() async throws {
        let outbox = makeOutbox()

        var held = message(subject: "Later")
        held.sendAfter = .now.addingTimeInterval(3_600)

        try await outbox.enqueue(held)

        let sender = makeSender(outbox)

        await drainAndSettle(sender)

        // `isSending` is about mail on its way out, not about a handover being
        // offered: a spinner over a message that is still an hour away is the
        // app claiming to do something it is not.
        #expect(sender.isSending == false)
        #expect(sender.pendingCount == 1, "it is still waiting, and the sidebar should say so")
        #expect(await outbox.pending().first?.isDeviceHeld == true)
    }

    /// What the app asks the system to wake it for. The earliest one, because
    /// a wake-up for the second would be too late for the first.
    @Test("The next due time is the earliest one still ahead")
    func nextDue() async throws {
        let outbox = makeOutbox()
        let soon = Date.now.addingTimeInterval(600)
        let later = Date.now.addingTimeInterval(6_000)

        var first = message(subject: "Later")
        first.sendAfter = later
        var second = message(subject: "Soon")
        second.sendAfter = soon
        var due = message(subject: "Now")
        due.sendAfter = .now.addingTimeInterval(-60)

        try await outbox.enqueue(first)
        try await outbox.enqueue(second)
        try await outbox.enqueue(due)

        let sender = makeSender(outbox)

        await sender.refreshCount()

        #expect(sender.nextDueAt == soon)
    }

    @Test("Nothing scheduled means nothing to wake for")
    func noNextDue() async throws {
        let outbox = makeOutbox()

        try await outbox.enqueue(message(subject: "Now"))

        let sender = makeSender(outbox)

        await sender.refreshCount()

        #expect(sender.nextDueAt == nil)
    }

    /// "Send now" is the way back out of a schedule, and it has to clear the
    /// time on disk — not just send once — or the message would be held again
    /// after a relaunch.
    @Test("Sending a held message now clears its schedule")
    func sendNow() async throws {
        let outbox = makeOutbox()

        var held = message(subject: "Held")
        held.sendAfter = .now.addingTimeInterval(3_600)

        try await outbox.enqueue(held)

        let sender = makeSender(outbox)

        await sender.sendNow(held.id)
        await sender.settle()

        // The send itself fails — there is no Drafts mailbox in this store —
        // which is what leaves the message here to be inspected.
        let stored = try #require(await outbox.pending().first)

        #expect(stored.sendAfter == nil)
        #expect(sender.nextDueAt == nil)
    }
}
