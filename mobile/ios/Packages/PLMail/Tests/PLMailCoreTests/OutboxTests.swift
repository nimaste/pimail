import Foundation
import JMAPKit
import Testing

@testable import PLMailCore

/// The queue is the one place in this app holding something that exists
/// nowhere else, so these tests are about survival: does a message written
/// offline come back, byte for byte, after the process that wrote it is gone.
@Suite("Outbox")
struct OutboxTests {
    /// Each test gets its own server id, so the on-disk directories cannot
    /// collide — the queue is deliberately real files, not a fake.
    private func makeOutbox() -> Outbox {
        Outbox(serverID: "test-\(UUID().uuidString)")
    }

    private func message(
        subject: String = "Hello",
        body: String = "Body",
        attachments: [Outbox.Attachment] = []
    ) -> Outbox.PendingMessage {
        Outbox.PendingMessage(
            accountKey: "srv/1",
            accountID: AccountID("1"),
            identityID: IdentityID(rawValue: "3"),
            from: EmailAddress(name: "Me", email: "me@example.com"),
            to: [EmailAddress(name: nil, email: "you@example.com")],
            subject: subject,
            body: body,
            attachments: attachments
        )
    }

    @Test("A queued message survives being reloaded from disk")
    func roundTrip() async throws {
        let outbox = makeOutbox()
        let queued = message(subject: "Written on a train", body: "No signal here.")

        try await outbox.enqueue(queued)

        let reloaded = await outbox.pending()

        #expect(reloaded.count == 1)
        #expect(reloaded.first?.id == queued.id)
        #expect(reloaded.first?.subject == "Written on a train")
        #expect(reloaded.first?.body == "No signal here.")
        #expect(reloaded.first?.to.first?.email == "you@example.com")
        #expect(reloaded.first?.from?.name == "Me")
        #expect(reloaded.first?.identityID.rawValue == "3")
    }

    /// Attachment bytes live beside the metadata rather than inside it. If
    /// they came back short or empty the send would succeed and the
    /// recipient would get an empty PDF, which is worse than a failure.
    @Test("Attachment bytes come back intact")
    func attachmentBytes() async throws {
        let outbox = makeOutbox()
        let bytes = Data((0..<4096).map { UInt8($0 % 251) })

        try await outbox.enqueue(
            message(
                attachments: [
                    Outbox.Attachment(name: "report.pdf", type: "application/pdf", data: bytes)
                ]))

        let attachment = try #require(await outbox.pending().first?.attachments.first)

        #expect(attachment.data == bytes)
        #expect(attachment.name == "report.pdf")
        #expect(attachment.type == "application/pdf")
    }

    /// Two files can genuinely be called the same thing, and the display name
    /// comes from a picker rather than from us. Storing by display name would
    /// mean the second overwrote the first.
    @Test("Two attachments with the same display name are both kept")
    func duplicateAttachmentNames() async throws {
        let outbox = makeOutbox()
        let first = Data("first".utf8)
        let second = Data("second".utf8)

        try await outbox.enqueue(
            message(attachments: [
                Outbox.Attachment(name: "photo.jpg", type: "image/jpeg", data: first),
                Outbox.Attachment(name: "photo.jpg", type: "image/jpeg", data: second),
            ]))

        let stored = try #require(await outbox.pending().first).attachments

        #expect(stored.count == 2)
        #expect(Set(stored.map(\.data)) == [first, second])
    }

    /// Oldest first. A reply queued after the message it answers must not
    /// arrive before it.
    @Test("Pending messages come back oldest first")
    func ordering() async throws {
        let outbox = makeOutbox()

        var first = message(subject: "First")
        first.queuedAt = Date(timeIntervalSince1970: 1_000)
        var second = message(subject: "Second")
        second.queuedAt = Date(timeIntervalSince1970: 2_000)
        var third = message(subject: "Third")
        third.queuedAt = Date(timeIntervalSince1970: 3_000)

        // Enqueued out of order on purpose: directory listings have no
        // guaranteed order, so sorting has to be the queue's job.
        try await outbox.enqueue(second)
        try await outbox.enqueue(third)
        try await outbox.enqueue(first)

        #expect(await outbox.pending().map(\.subject) == ["First", "Second", "Third"])
    }

    @Test("Removing a message empties the queue")
    func remove() async throws {
        let outbox = makeOutbox()
        let queued = try await outbox.enqueue(message())

        await outbox.remove(queued.id)

        #expect(await outbox.count() == 0)
    }

    /// A failure has to be durable too: relaunching should still say why the
    /// message is sitting there, and should not have reset the attempt count.
    @Test("A recorded failure persists and does not duplicate the message")
    func recordFailure() async throws {
        let outbox = makeOutbox()
        let queued = try await outbox.enqueue(message(subject: "Stuck"))

        await outbox.recordFailure(queued.id, reason: "Waiting for the server.")
        await outbox.recordFailure(queued.id, reason: "Waiting for the server.")

        let pending = await outbox.pending()

        #expect(pending.count == 1)
        #expect(pending.first?.attempts == 2)
        #expect(pending.first?.lastFailure == "Waiting for the server.")
        #expect(pending.first?.lastAttemptAt != nil)
    }

    /// Recording a failure must not lose the bytes it was carrying — it
    /// rewrites the same folder the attachments live in.
    @Test("A failure keeps the attachments")
    func failureKeepsAttachments() async throws {
        let outbox = makeOutbox()
        let bytes = Data("payload".utf8)
        let queued = try await outbox.enqueue(
            message(attachments: [
                Outbox.Attachment(name: "a.txt", type: "text/plain", data: bytes)
            ]))

        await outbox.recordFailure(queued.id, reason: "Nope.")

        #expect(await outbox.pending().first?.attachments.first?.data == bytes)
    }

    // MARK: - Scheduled sends

    /// The time a message is held until is the one field that must survive a
    /// relaunch even more surely than the rest: the app is expected to be dead
    /// for most of the wait.
    @Test("A scheduled time survives being reloaded from disk")
    func scheduledRoundTrip() async throws {
        let outbox = makeOutbox()
        let when = Date(timeIntervalSince1970: 1_800_000_000)

        var queued = message(subject: "In the morning")
        queued.sendAfter = when

        try await outbox.enqueue(queued)

        #expect(await outbox.pending().first?.sendAfter == when)
    }

    /// The queue on disk is versioned only by being lenient. A message written
    /// by the build before this one has no `sendAfter` at all, and it must
    /// come back meaning what it always meant: send at the next opportunity.
    @Test("A message written before scheduling existed still decodes, and is due")
    func decodesQueueWithoutSendAfter() async throws {
        let outbox = makeOutbox()
        let id = UUID()
        let folder = await outbox.directory.appending(
            path: id.uuidString, directoryHint: .isDirectory)

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // Written out by hand rather than by encoding a current record with
        // the field left off: the point is the bytes an older build produced.
        let legacy = """
            {
              "id": "\(id.uuidString)",
              "accountKey": "srv/1",
              "accountID": "1",
              "identityID": "3",
              "to": [{ "email": "you@example.com" }],
              "cc": [],
              "bcc": [],
              "subject": "From the last build",
              "body": "Still here.",
              "queuedAt": 700000000,
              "attempts": 0,
              "attachments": []
            }
            """

        try Data(legacy.utf8).write(to: folder.appending(path: "message.json"))

        let reloaded = try #require(await outbox.pending().first)

        #expect(reloaded.subject == "From the last build")
        #expect(reloaded.sendAfter == nil)
        #expect(reloaded.isDue())
    }

    @Test("Due-ness is decided by the clock, not by a flag")
    func dueness() {
        let now = Date(timeIntervalSince1970: 1_000_000)

        var unscheduled = message()
        #expect(unscheduled.isDue(at: now))

        unscheduled.sendAfter = now.addingTimeInterval(60)
        #expect(unscheduled.isDue(at: now) == false)

        unscheduled.sendAfter = now
        #expect(unscheduled.isDue(at: now), "the moment it is due, it is due")

        unscheduled.sendAfter = now.addingTimeInterval(-1)
        #expect(unscheduled.isDue(at: now))
    }

    /// Sending a held message now, and moving one — both rewrite the folder
    /// rather than requeueing, so neither may lose the attachments.
    @Test("Rescheduling keeps everything but the time")
    func reschedule() async throws {
        let outbox = makeOutbox()
        let bytes = Data("payload".utf8)

        var queued = message(
            subject: "Held",
            attachments: [
                Outbox.Attachment(name: "a.txt", type: "text/plain", data: bytes)
            ])
        queued.sendAfter = Date(timeIntervalSince1970: 1_800_000_000)

        try await outbox.enqueue(queued)

        let moved = Date(timeIntervalSince1970: 1_900_000_000)

        await outbox.reschedule(queued.id, to: moved)

        var stored = try #require(await outbox.pending().first)

        #expect(await outbox.count() == 1)
        #expect(stored.sendAfter == moved)
        #expect(stored.subject == "Held")
        #expect(stored.attachments.first?.data == bytes)

        await outbox.reschedule(queued.id, to: nil)

        stored = try #require(await outbox.pending().first)

        #expect(stored.sendAfter == nil)
        #expect(stored.isDue())
        #expect(stored.attachments.first?.data == bytes)
    }

    /// Signing into a different server must not inherit the previous one's
    /// unsent mail — it would be sent from an identity that no longer exists.
    @Test("Queues are scoped to one server")
    func scoping() async throws {
        let first = Outbox(serverID: "nas.local")
        let second = Outbox(serverID: "other.example")

        _ = try await first.enqueue(message(subject: "For the NAS"))

        #expect(await second.count() == 0)

        // Cleanup, since these two use fixed ids rather than a fresh one.
        for queued in await first.pending() { await first.remove(queued.id) }
    }

    /// Hostnames contain dots and can contain characters a path segment
    /// should not. A colon or a slash reaching the filesystem is either a
    /// write failure or a write somewhere unintended.
    @Test(
        "Server ids are reduced to safe directory names",
        arguments: [
            ("nas.local", "nas.local"),
            ("mail.example.com:8443", "mail.example.com-8443"),
            ("../escape", "..-escape"),
            ("a/b", "a-b"),
        ])
    func slugging(serverID: String, expected: String) {
        #expect(Outbox.slug(serverID) == expected)
    }
}
