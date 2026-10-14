import Foundation
import JMAPKit
import JMAPTestSupport
import Testing

@testable import PLMailCore

/// Canned bodies, outside the suite so the transport closure — which runs off
/// the main actor — can read them.
private enum DraftFixtures {
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

    static let draftJSON = """
        {
          "methodResponses": [["Email/get", {
            "accountId": "1",
            "state": "s1",
            "list": [{
              "id": "42",
              "subject": "Quarterly numbers",
              "to": [{ "name": "Ada", "email": "ada@example.org" }],
              "cc": [{ "name": null, "email": "bob@example.org" }],
              "bcc": [{ "name": null, "email": "secret@example.org" }],
              "htmlBody": [{ "partId": "html", "type": "text/html" }],
              "bodyValues": { "html": { "value": "<div>Here they are.</div>" } },
              "attachments": [
                { "partId": "2", "blobId": "p-9", "name": "q3.pdf",
                  "type": "application/pdf", "size": 1234, "disposition": "attachment" },
                { "partId": "3", "blobId": "p-10", "name": "logo.png",
                  "type": "image/png", "size": 90, "cid": "logo", "disposition": "inline" }
              ]
            }],
            "notFound": []
          }, "c0"]]
        }
        """

    static let identityJSON = """
        {"methodResponses": [["Identity/get", {"accountId": "1", "state": "s1",
        "list": [], "notFound": []}, "c0"]]}
        """

    static let setJSON = """
        {"methodResponses": [["Email/set", {"accountId": "1", "newState": "s2",
        "updated": {"42": null}, "notUpdated": {}}, "c0"]]}
        """

    static let createJSON = """
        {"methodResponses": [["Email/set", {"accountId": "1", "newState": "s2",
        "created": {"draft": {"id": "99", "blobId": "b-1", "threadId": "t-1"}},
        "notCreated": {}}, "c0"]]}
        """

}

/// Reopening a draft and saving it again.
///
/// This is the destructive path: the composer used to restore to, cc, subject
/// and body only, and then rewrite the draft from what it held — so opening a
/// draft with a Bcc line and two PDFs to check it, and pressing Send, delivered
/// it with neither and deleted the stored parts.
@Suite("Compose drafts")
@MainActor
struct ComposeDraftTests {
    // MARK: - Fixtures

    /// Answers by looking at which method was asked for, so one composer's
    /// whole lifecycle can be driven from one transport.
    private static func transport() -> MockTransport {
        MockTransport { request in
            let isDiscovery = request.url?.path().contains(".well-known") == true

            guard isDiscovery == false else {
                return (Data(DraftFixtures.sessionJSON.utf8), MockTransport.response(for: request))
            }

            let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""

            let answer: String =
                if body.contains("Email/get") {
                    DraftFixtures.draftJSON
                } else if body.contains("Identity/get") {
                    DraftFixtures.identityJSON
                } else if body.contains("\"create\"") {
                    DraftFixtures.createJSON
                } else {
                    DraftFixtures.setJSON
                }

            return (Data(answer.utf8), MockTransport.response(for: request))
        }
    }

    private static func model(
        kind: ComposeModel.Kind, transport: MockTransport
    ) -> ComposeModel {
        ComposeModel(
            kind: kind,
            accountKey: "nas.local/1",
            accountID: AccountID("1"),
            client: JMAPClient(
                discoveryURL: URL(string: "https://nas.local/.well-known/jmap")!,
                credential: .appPassword("plmail_test"),
                transport: transport),
            store: SyncStore(modelContainer: MailStack.makeContainer(inMemory: true)),
            outbox: Outbox(serverID: "test-\(UUID().uuidString)"),
            contacts: NoContacts()
        )
    }

    /// The `Email/set` bodies the composer sent, newest last.
    private static func draftPatches(_ transport: MockTransport) -> [[String: Any]] {
        transport.recorded.compactMap { recorded -> [String: Any]? in
            guard let body = recorded.body,
                let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                let calls = json["methodCalls"] as? [[Any]],
                let call = calls.first,
                call.first as? String == "Email/set",
                let arguments = call.dropFirst().first as? [String: Any],
                let update = arguments["update"] as? [String: Any],
                let patch = update["42"] as? [String: Any]
            else { return nil }

            return patch
        }
    }

    // MARK: - Reopening

    @Test("Reopening a draft restores its Bcc")
    func bccIsRestored() async {
        let model = Self.model(kind: .editDraft(emailID: "42"), transport: Self.transport())

        await model.load()

        #expect(model.to.contains("ada@example.org"))
        #expect(model.cc.contains("bob@example.org"))
        #expect(model.bcc.contains("secret@example.org"))
        #expect(model.subject == "Quarterly numbers")
    }

    @Test("A reopened draft's files come back as blob ids and inline parts do not")
    func attachmentsAreRestoredAsync() async throws {
        let model = Self.model(kind: .editDraft(emailID: "42"), transport: Self.transport())

        await model.load()

        #expect(model.attachments.count == 1)

        let file = try #require(model.attachments.first)

        #expect(file.name == "q3.pdf")
        #expect(file.blobID == BlobID("p-9"))
        // Held as an id, never as bytes: a `cid:` image belongs to the body and
        // listing it as removable confuses people into deleting half their own
        // message.
        #expect(file.data == nil)
    }

    // MARK: - Saving

    @Test("Editing the subject saves Bcc and leaves the attachment set alone")
    func saveKeepsBccAndDoesNotRestateAttachments() async throws {
        let transport = Self.transport()
        let model = Self.model(kind: .editDraft(emailID: "42"), transport: transport)

        await model.load()

        model.subject = "Quarterly numbers, revised"

        await model.saveDraft()

        let patch = try #require(Self.draftPatches(transport).last)

        #expect(patch["subject"] as? String == "Quarterly numbers, revised")
        #expect((patch["bcc"] as? [[String: Any]])?.count == 1)
        // The whole point: an unchanged set is not a whole value, so nothing
        // here can delete the stored part.
        #expect(patch["attachments"] == nil)
    }

    @Test("Removing the last file does send an empty array")
    func removingAFileIsWrittenThrough() async throws {
        let transport = Self.transport()
        let model = Self.model(kind: .editDraft(emailID: "42"), transport: transport)

        await model.load()

        let file = try #require(model.attachments.first)

        model.removeAttachment(file.id)

        await model.saveDraft()

        let patch = try #require(Self.draftPatches(transport).last)
        let files = try #require(patch["attachments"] as? [Any])

        #expect(files.isEmpty)
    }

    @Test("Saving twice with nothing changed makes one request, not two")
    func unchangedDraftIsNotResaved() async {
        let transport = Self.transport()
        let model = Self.model(kind: .editDraft(emailID: "42"), transport: transport)

        await model.load()

        model.subject = "Changed"

        await model.saveDraft()

        let after = Self.draftPatches(transport).count

        await model.saveDraft()

        #expect(Self.draftPatches(transport).count == after)
    }

    // MARK: - Emptiness

    @Test("A composer with nothing but a signature in it is empty")
    func signatureIsNotContent() {
        #expect(ComposeModel.isBlank("\n\n-- \nAda", ignoring: "\n\n-- \nAda"))
        #expect(ComposeModel.isBlank("\u{00A0}\n ", ignoring: nil))
        #expect(ComposeModel.isBlank("Hello\n\n-- \nAda", ignoring: "\n\n-- \nAda") == false)
    }

    /// Opening a draft to look at it is not editing it. A save here would be a
    /// request per glance, and — before the attachment set was tracked — a
    /// chance to lose the files.
    @Test("Opening a draft and touching nothing writes nothing back")
    func openingADraftIsNotAnEdit() async {
        let transport = Self.transport()
        let model = Self.model(kind: .editDraft(emailID: "42"), transport: transport)

        await model.load()
        await model.saveDraft()

        #expect(Self.draftPatches(transport).isEmpty)
    }

    /// The identity list is not loaded when the composer is built, so reply-all
    /// is recomputed once it is. That recomputation is the app writing, not the
    /// user — counting it as typing meant merely opening a reply-all left a
    /// draft behind three seconds later.
    @Test("Opening a reply-all writes nothing back either")
    func openingAReplyIsNotAnEdit() async {
        var message = MessageSnapshot(
            emailID: "7",
            accountKey: "nas.local/1",
            to: [EmailAddress(name: nil, email: "me@example.org")],
            cc: [EmailAddress(name: nil, email: "bob@example.org")],
            references: [],
            preview: "Tuesday?",
            isSeen: true,
            isFlagged: false,
            isDraft: false,
            hasBody: true,
            attachments: [],
            inlineParts: []
        )
        message.fromAddress = "ada@example.org"
        message.subject = "AW: Angebot"

        let transport = Self.transport()
        let model = Self.model(kind: .reply(to: message, all: true), transport: transport)

        await model.load()

        #expect(model.subject == "Re: Angebot")

        await model.saveDraft()

        #expect(Self.draftPatches(transport).isEmpty)
    }

    @Test("An untouched new composer never writes a draft")
    func emptyComposerDoesNotSave() async {
        let transport = Self.transport()
        let model = Self.model(kind: .new, transport: transport)

        await model.load()
        await model.saveDraft()

        #expect(model.isEmpty)
        #expect(model.draftID == nil)
    }

    // MARK: - Sending

    /// Bcc exists so a list of people cannot see each other's addresses.
    /// Requiring `To` meant that message could not be sent at all — a disabled
    /// button and no explanation.
    @Test("A message addressed only by Bcc can be sent")
    func bccOnlyCanSend() {
        let model = Self.model(kind: .new, transport: Self.transport())

        #expect(model.canSend == false)

        model.bcc = "everyone@example.org"

        #expect(model.canSend)
    }

    @Test("An address that is not an address does not enable Send")
    func typoDoesNotCount() {
        let model = Self.model(kind: .new, transport: Self.transport())

        model.to = "ada"

        #expect(model.canSend == false)
        #expect(model.invalidRecipients == ["ada"])
    }

    // MARK: - Back-off

    /// A failed autosave must never become a loop against somebody's NAS.
    @Test("Each failed save doubles the wait, up to a ceiling")
    func backoff() {
        #expect(ComposeModel.autosaveDelay(afterFailures: 0) == ComposeModel.autosaveDebounce)
        #expect(
            ComposeModel.autosaveDelay(afterFailures: 1) == ComposeModel.autosaveDebounce * 2)
        #expect(
            ComposeModel.autosaveDelay(afterFailures: 20)
                == ComposeModel.autosaveBackoffCeiling)
    }

    // MARK: - Limits

    @Test("The ceiling comes from the Session rather than from a guess")
    func limitsAreReadFromTheSession() async {
        let model = Self.model(kind: .new, transport: Self.transport())

        await model.load()

        #expect(model.limits.maxTotalBytes == 40_000_000)
        #expect(model.limits.maxFileBytes == 50_000_000)
    }

    @Test("A file over the ceiling is refused by name, and nothing is truncated")
    func oversizeFileIsRefused() {
        let model = Self.model(kind: .new, transport: Self.transport())
        let refused = model.attach(
            name: "holiday.mov", type: "video/quicktime",
            data: Data(count: model.limits.maxFileBytes + 1))

        #expect(refused == false)
        #expect(model.attachments.isEmpty)
        #expect(model.attachmentRefusal?.contains("holiday.mov") == true)
    }
}

/// No address book, so a compose test never waits on permission.
private struct NoContacts: ContactSource {
    func addresses(matching fragment: String) async -> [EmailAddress] { [] }
}
