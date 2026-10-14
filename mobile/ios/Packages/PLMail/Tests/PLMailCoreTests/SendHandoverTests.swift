import Foundation
import JMAPKit
import JMAPTestSupport
import Testing

@testable import PLMailCore

/// Canned bodies, outside the suite so the transport closure — which runs off
/// the main actor — can read them.
private enum HandoverFixtures {
    static let sessionJSON = """
        {
          "capabilities": {
            "urn:ietf:params:jmap:core": {
              "maxSizeUpload": 50000000,
              "maxConcurrentUpload": 4,
              "maxSizeRequestObject": 10000000,
              "maxConcurrentRequests": 4,
              "maxCallsInRequest": 32,
              "maxObjectsInGet": 500,
              "maxObjectsInSet": 500,
              "collationAlgorithms": ["i;unicode-casemap"]
            }
          },
          "accounts": {
            "1": {
              "name": "me@example.org",
              "isPersonal": true,
              "isReadOnly": false,
              "accountCapabilities": {
                "urn:ietf:params:jmap:mail": { "maxSizeAttachmentsPerEmail": 40000000 }
              }
            }
          },
          "primaryAccounts": { "urn:ietf:params:jmap:mail": "1" },
          "username": "me@example.org",
          "apiUrl": "https://nas.local/jmap/api",
          "downloadUrl": "https://nas.local/jmap/download/{accountId}/{blobId}/{name}",
          "uploadUrl": "https://nas.local/jmap/upload/{accountId}",
          "eventSourceUrl": "https://nas.local/jmap/eventsource",
          "state": "s0"
        }
        """

    /// A create and a submission the server took, with the release time it
    /// chose — which is deliberately a minute later than anything a test asks
    /// for, so an implementation that records the requested time rather than
    /// the answer is caught.
    static let acceptedJSON = """
        {"methodResponses": [
          ["Email/set", {"accountId": "1", "newState": "s2",
            "created": {"draft": {"id": "99", "blobId": "b-1", "threadId": "t-1"}},
            "notCreated": {}}, "c0"],
          ["EmailSubmission/set", {"accountId": "1", "newState": "s3",
            "created": {"send": {"id": "99", "sendAt": "2027-01-15T08:00:00Z",
              "undoStatus": "pending"}},
            "notCreated": {}}, "c1"]
        ]}
        """

    /// The draft is created and the **envelope** is refused — the shape a hold
    /// past `maxDelayedSend` comes back in.
    static let holdRefusedJSON = """
        {"methodResponses": [
          ["Email/set", {"accountId": "1", "newState": "s2",
            "created": {"draft": {"id": "99", "blobId": "b-1", "threadId": "t-1"}},
            "notCreated": {}}, "c0"],
          ["EmailSubmission/set", {"accountId": "1", "newState": "s2",
            "created": {},
            "notCreated": {"send": {"type": "invalidProperties",
              "description": "\\"HOLDUNTIL\\" must be within 2592000 seconds; see maxDelayedSend in the session."}}}, "c1"]
        ]}
        """

    static let cancelledJSON = """
        {"methodResponses": [["EmailSubmission/set", {"accountId": "1",
          "newState": "s4", "updated": {"99": null}, "notUpdated": {}}, "c0"]]}
        """

    static let tooLateJSON = """
        {"methodResponses": [["EmailSubmission/set", {"accountId": "1",
          "newState": "s4", "updated": {},
          "notUpdated": {"99": {"type": "cannotUnsend",
            "description": "That Email has already been sent."}}}, "c0"]]}
        """

    static let sentJSON = """
        {"methodResponses": [["EmailSubmission/get", {"accountId": "1", "state": "s5",
          "list": [{"id": "99", "emailId": "99", "sendAt": "2027-01-15T08:00:00Z",
            "undoStatus": "final"}], "notFound": []}, "c0"]]}
        """

    /// The server still has it and has not sent it. The answer that must not
    /// cause anything local to happen.
    static let stillPendingJSON = """
        {"methodResponses": [["EmailSubmission/get", {"accountId": "1", "state": "s5",
          "list": [{"id": "99", "emailId": "99", "sendAt": "2027-01-15T08:00:00Z",
            "undoStatus": "pending"}], "notFound": []}, "c0"]]}
        """

    static let neverSubmittedJSON = """
        {"methodResponses": [["EmailSubmission/get", {"accountId": "1", "state": "s5",
          "list": [], "notFound": ["99"]}, "c0"]]}
        """
}

/// Handing a scheduled message from this device to the server, and back.
///
/// **The two failures worth testing are opposites.** A message must never be
/// sent twice — once by the server that accepted a hold and once by a phone
/// that never noticed — and it must never be dropped between the two, which is
/// what a handover that removes the local row before the server has said yes
/// produces. Everything here is one of those two.
@Suite("Send handover")
@MainActor
struct SendHandoverTests {
    // MARK: - Fixtures

    /// Answers by looking at what was asked, so one queue's whole lifecycle can
    /// be driven from one transport.
    private static func transport(reply: @escaping @Sendable (String) -> String) -> MockTransport {
        MockTransport { request in
            guard request.url?.path().contains(".well-known") != true else {
                return (
                    Data(HandoverFixtures.sessionJSON.utf8), MockTransport.response(for: request)
                )
            }

            let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""

            return (Data(reply(body).utf8), MockTransport.response(for: request))
        }
    }

    private static func store() async throws -> SyncStore {
        let store = SyncStore(modelContainer: MailStack.makeContainer(inMemory: true))

        var drafts = Mailbox(id: MailboxID("3"))
        drafts.name = "Drafts"
        drafts.role = .drafts

        try await store.replaceMailboxes(
            [drafts], accountKey: "srv/1", state: StateToken(rawValue: "1"))

        return store
    }

    private static func sender(
        _ outbox: Outbox, _ transport: MockTransport
    ) async throws
        -> OutboxSender
    {
        OutboxSender(
            outbox: outbox,
            client: JMAPClient(
                discoveryURL: URL(string: "https://nas.local/.well-known/jmap")!,
                credential: .appPassword("plmail_test"),
                transport: transport),
            store: try await store())
    }

    private static func outbox() -> Outbox {
        Outbox(serverID: "handover-\(UUID().uuidString)")
    }

    private static func message(sendAfter: Date?) -> Outbox.PendingMessage {
        var message = Outbox.PendingMessage(
            accountKey: "srv/1",
            accountID: AccountID("1"),
            identityID: IdentityID(rawValue: "3"),
            from: EmailAddress(name: "Me", email: "me@example.org"),
            to: [EmailAddress(email: "ada@example.org")],
            subject: "Quarterly numbers",
            body: "Here they are."
        )
        message.sendAfter = sendAfter

        return message
    }

    private static func drain(_ sender: OutboxSender) async {
        sender.drain()
        await sender.settle()
    }

    /// Every submission body the client sent.
    private static func submissions(_ transport: MockTransport) -> [[String: Any]] {
        transport.recorded.compactMap { recorded in
            guard let body = recorded.body,
                let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                let calls = json["methodCalls"] as? [[Any]]
            else { return nil }

            for call in calls where call.first as? String == "EmailSubmission/set" {
                return call.dropFirst().first as? [String: Any]
            }

            return nil
        }
    }

    // MARK: - Within the ceiling: the server takes it

    /// The whole point of the wave: a message the server can hold stops being
    /// this phone's problem.
    @Test("A schedule the server accepts is recorded from the server's own answer")
    func withinTheCeilingGoesToTheServer() async throws {
        let outbox = Self.outbox()
        let transport = Self.transport { _ in HandoverFixtures.acceptedJSON }

        try await outbox.enqueue(Self.message(sendAfter: .now.addingTimeInterval(3_600)))
        await Self.drain(try await Self.sender(outbox, transport))

        let stored = try #require(await outbox.pending().first)
        let handover = try #require(stored.handover)

        #expect(handover.submissionID == "99")
        // The server's release time, not the one that was asked for. They agree
        // on this server and would not on one that rounds, and the Outbox has
        // to show when the mail actually leaves.
        #expect(handover.sendAt == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(stored.isDeviceHeld == false)

        // And the hold really was expressed as an instant.
        let parameters =
            ((Self.submissions(transport).first?["create"] as? [String: Any])?["send"]
            as? [String: Any])
            .flatMap { ($0["envelope"] as? [String: Any])?["mailFrom"] as? [String: Any] }
            .flatMap { $0["parameters"] as? [String: Any] }

        #expect(parameters?["HOLDUNTIL"] != nil)
    }

    /// **Never twice.** Once the server has it, every later drain has to leave
    /// it alone — including drains that happen long after the release time,
    /// which is exactly when a naive `sendAfter <= now` check would fire.
    @Test("A message the server accepted is never submitted again")
    func acceptedIsSubmittedOnce() async throws {
        let outbox = Self.outbox()
        // The server keeps saying it is still holding the message, which is
        // the only answer under which a second submission would be a genuine
        // double send rather than a recovery.
        let transport = Self.transport { body in
            body.contains("EmailSubmission/get")
                ? HandoverFixtures.stillPendingJSON : HandoverFixtures.acceptedJSON
        }
        let sender = try await Self.sender(outbox, transport)

        // An hour out, not seconds: the row must still be *held* when the first
        // drain runs, and a two-second window is one the machine can miss under
        // load — at which point the message is genuinely due, the drain
        // correctly sends it rather than holding it, the row is gone, and the
        // `#require` below fails for a reason that has nothing to do with what
        // this test guards. The release time is simulated by the backdated
        // handover further down, not by waiting.
        try await outbox.enqueue(Self.message(sendAfter: .now.addingTimeInterval(3_600)))
        await Self.drain(sender)

        let submissionsAfterFirst = Self.submissions(transport).count

        #expect(submissionsAfterFirst == 1)

        // The release time passes, and the queue is drained again and again.
        await outbox.recordHandover(
            try #require(await outbox.pending().first).id,
            Outbox.PendingMessage.Handover(
                submissionID: "99", sendAt: .now.addingTimeInterval(-3_600)))

        await Self.drain(sender)
        await Self.drain(sender)

        // Reconcile may ask *about* it. Nothing may submit it.
        #expect(Self.submissions(transport).count == submissionsAfterFirst)
    }

    // MARK: - Past the ceiling: the phone keeps it

    /// **Never dropped.** A hold the server refuses leaves the message exactly
    /// where it was, still scheduled, still this device's — which is the
    /// fallback the outbox exists for.
    @Test("A schedule past the server's ceiling falls back to the outbox")
    func pastTheCeilingStaysHere() async throws {
        let outbox = Self.outbox()
        let transport = Self.transport { _ in HandoverFixtures.holdRefusedJSON }
        let when = Date.now.addingTimeInterval(90 * 86_400)

        try await outbox.enqueue(Self.message(sendAfter: when))
        await Self.drain(try await Self.sender(outbox, transport))

        let stored = try #require(await outbox.pending().first)

        #expect(stored.handover == nil, "a refusal must never look like an acceptance")
        #expect(stored.isDeviceHeld)
        #expect(stored.sendAfter == when, "the schedule survives the refusal intact")
        // The draft the create made is remembered, so the eventual send rewrites
        // it rather than leaving a second copy in Drafts — and, more to the
        // point, cannot submit a different Email.
        #expect(stored.editingEmailID == "99")
        #expect(stored.lastFailure != nil, "the weaker promise is said out loud")
    }

    /// A refused hold must not become an immediate send. The user asked for a
    /// time; sending now is the one answer that cannot be undone.
    @Test("A refused hold does not send the message immediately")
    func refusedHoldDoesNotSendNow() async throws {
        let outbox = Self.outbox()
        let transport = Self.transport { _ in HandoverFixtures.holdRefusedJSON }

        try await outbox.enqueue(Self.message(sendAfter: .now.addingTimeInterval(90 * 86_400)))
        await Self.drain(try await Self.sender(outbox, transport))

        #expect(await outbox.pending().count == 1, "still queued, not gone")
        #expect(try #require(await outbox.pending().first).isDue(at: .now) == false)
    }

    // MARK: - Undo

    /// The replacement for the five-second composer block: the message really
    /// is submitted, and the window is the server's hold.
    @Test("An immediate send is submitted with a hold, so the undo has something to cancel")
    func immediateSendIsHeldByTheServer() async throws {
        let outbox = Self.outbox()
        let transport = Self.transport { _ in HandoverFixtures.acceptedJSON }

        var message = Self.message(sendAfter: nil)
        message.undoGraceSeconds = ComposeModel.undoGrace

        try await outbox.enqueue(message)
        await Self.drain(try await Self.sender(outbox, transport))

        let parameters =
            ((Self.submissions(transport).first?["create"] as? [String: Any])?["send"]
            as? [String: Any])
            .flatMap { ($0["envelope"] as? [String: Any])?["mailFrom"] as? [String: Any] }
            .flatMap { $0["parameters"] as? [String: Any] }

        #expect(parameters?["HOLDFOR"] as? String == String(ComposeModel.undoGrace))
        // The row survives the send, because a cancel needs something to point
        // at. Before this, the composer closed and there was no undo at all.
        #expect(try #require(await outbox.pending().first).handover?.submissionID == "99")
    }

    /// A cancel of a submission the server accepted is a real server operation.
    @Test("Cancelling after the server accepted actually cancels")
    func cancelAfterAcceptance() async throws {
        let outbox = Self.outbox()
        let transport = Self.transport { body in
            body.contains("undoStatus")
                ? HandoverFixtures.cancelledJSON : HandoverFixtures.acceptedJSON
        }
        let sender = try await Self.sender(outbox, transport)

        try await outbox.enqueue(Self.message(sendAfter: .now.addingTimeInterval(3_600)))
        await Self.drain(sender)

        let queued = try #require(await outbox.pending().first)

        #expect(await sender.cancel(queued.id) == .cancelled)
        #expect(await outbox.pending().isEmpty, "nothing is left claiming to be scheduled")

        // And it was a cancel, not a local delete.
        let cancels = Self.submissions(transport).compactMap { $0["update"] as? [String: Any] }

        #expect(
            (cancels.first?["99"] as? [String: Any])?["undoStatus"] as? String == "canceled")
    }

    /// **The sentence this path exists to avoid.** Telling somebody a message
    /// was called back while their recipient is reading it is worse than the
    /// missed cancel.
    @Test("A cancel the server refuses is reported as already sent, never as undone")
    func tooLateIsSaidOutLoud() async throws {
        let outbox = Self.outbox()
        let transport = Self.transport { body in
            body.contains("undoStatus")
                ? HandoverFixtures.tooLateJSON : HandoverFixtures.acceptedJSON
        }
        let sender = try await Self.sender(outbox, transport)

        try await outbox.enqueue(Self.message(sendAfter: .now.addingTimeInterval(3_600)))
        await Self.drain(sender)

        let queued = try #require(await outbox.pending().first)

        #expect(await sender.cancel(queued.id) == .alreadySent)
    }

    /// A message this device is still holding cancels without a request: there
    /// is nothing on the server to call back.
    @Test("Cancelling a device-held message needs no server at all")
    func deviceHeldCancelIsLocal() async throws {
        let outbox = Self.outbox()
        let transport = Self.transport { _ in HandoverFixtures.holdRefusedJSON }
        let sender = try await Self.sender(outbox, transport)

        let message = try await outbox.enqueue(Self.message(sendAfter: .now.addingTimeInterval(60)))

        #expect(await sender.cancel(message.id) == .cancelled)
        #expect(await outbox.pending().isEmpty)
    }

    // MARK: - Retiring

    /// A row that is still saying "leaving at 08:00" at half past nine is worse
    /// than no row.
    @Test("A submission the server says is final stops being shown")
    func finalSubmissionsAreRetired() async throws {
        let outbox = Self.outbox()
        let transport = Self.transport { _ in HandoverFixtures.sentJSON }
        let sender = try await Self.sender(outbox, transport)

        let message = try await outbox.enqueue(Self.message(sendAfter: nil))
        await outbox.recordHandover(
            message.id,
            Outbox.PendingMessage.Handover(
                submissionID: "99", sendAt: .now.addingTimeInterval(-3_600)))

        await Self.drain(sender)

        #expect(await outbox.pending().isEmpty)
    }

    /// **Never dropped, the other way round.** If the server has no record of
    /// the submission, nothing anywhere is going to send this message — so it
    /// comes back to the device rather than sitting there as a receipt for
    /// something that never happened.
    @Test("A submission the server has never heard of comes back to this phone")
    func unknownSubmissionsComeBack() async throws {
        let outbox = Self.outbox()
        // Reconcile answers notFound; anything else would be a fresh send, and
        // this test asserts the row is sendable again rather than gone.
        let transport = Self.transport { body in
            body.contains("EmailSubmission/get")
                ? HandoverFixtures.neverSubmittedJSON : HandoverFixtures.acceptedJSON
        }
        let sender = try await Self.sender(outbox, transport)

        let message = try await outbox.enqueue(
            Self.message(sendAfter: .now.addingTimeInterval(3_600)))
        await outbox.recordHandover(
            message.id,
            Outbox.PendingMessage.Handover(
                submissionID: "99", sendAt: .now.addingTimeInterval(-3_600)))

        await Self.drain(sender)

        let stored = await outbox.pending().first

        #expect(stored != nil, "a message nobody is sending must not vanish")
    }

    /// Silence before the release time means nothing, and a scheduled message
    /// must not cost a request every time somebody glances at their phone.
    @Test("A schedule that is not due yet costs no reconcile request")
    func futureSchedulesAreNotAskedAbout() async throws {
        let outbox = Self.outbox()
        let transport = Self.transport { _ in HandoverFixtures.sentJSON }
        let sender = try await Self.sender(outbox, transport)

        let message = try await outbox.enqueue(Self.message(sendAfter: nil))
        await outbox.recordHandover(
            message.id,
            Outbox.PendingMessage.Handover(
                submissionID: "99", sendAt: .now.addingTimeInterval(7 * 86_400)))

        await Self.drain(sender)

        let asked = transport.recorded.contains {
            String(data: $0.body ?? Data(), encoding: .utf8)?.contains("EmailSubmission/get")
                == true
        }

        #expect(asked == false)
        #expect(await outbox.pending().count == 1)
    }

    // MARK: - Durability

    /// The crash guard. A queue written by a build that had never heard of
    /// server-side scheduling has to read back as what it always was: a message
    /// this device owns.
    @Test("A message filed before handovers existed reads back as device-held")
    func oldRecordsStillDecode() async throws {
        let outbox = Self.outbox()
        let message = try await outbox.enqueue(Self.message(sendAfter: nil))
        let reloaded = try #require(await outbox.pending().first)

        #expect(reloaded.id == message.id)
        #expect(reloaded.handover == nil)
        #expect(reloaded.isDue(at: .now))
    }

    /// A handover has to survive a relaunch, or the next drain sends the mail a
    /// second time.
    @Test("A handover survives being written and read back")
    func handoverRoundTrips() async throws {
        let outbox = Self.outbox()
        let message = try await outbox.enqueue(Self.message(sendAfter: nil))
        let when = Date(timeIntervalSince1970: 1_800_000_000)

        await outbox.recordHandover(
            message.id,
            Outbox.PendingMessage.Handover(submissionID: "99", sendAt: when))

        let reloaded = try #require(await outbox.pending().first)

        #expect(reloaded.handover?.submissionID == "99")
        #expect(reloaded.handover?.sendAt == when)
        #expect(reloaded.isDue(at: when.addingTimeInterval(86_400)) == false)
    }
}
