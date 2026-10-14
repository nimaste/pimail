import Foundation
import JMAPKit
import JMAPTestSupport
import Synchronization
import Testing

@testable import PLMailCore

/// Canned bodies, outside the suite so the transport closure — which runs off
/// the main actor — can read them.
private enum ConflictFixtures {
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

    /// The draft as the server holds it, read at state `s1` — which is the
    /// token every later save is conditional on.
    static let draftJSON = """
        {
          "methodResponses": [["Email/get", {
            "accountId": "1",
            "state": "s1",
            "list": [{
              "id": "42",
              "subject": "Quarterly numbers",
              "to": [{ "name": "Ada", "email": "ada@example.org" }],
              "htmlBody": [{ "partId": "html", "type": "text/html" }],
              "bodyValues": { "html": { "value": "<div>Here they are.</div>" } },
              "attachments": []
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
        {"methodResponses": [["Email/set", {"accountId": "1", "newState": "s4",
        "updated": {"42": null}, "notUpdated": {}}, "c0"]]}
        """

    /// A method-level refusal, which is where `ifInState` failures arrive —
    /// the server throws before it looks at a single object, so there is no
    /// `notUpdated` bucket to read.
    static let stateMismatchJSON = """
        {"methodResponses": [["error", {"type": "stateMismatch",
        "description": "The account has changed since ifInState was issued."}, "c0"]]}
        """

    /// The change log with something *other* than the draft in it: mail
    /// arrived. This is the common case, and reporting it as a conflict is the
    /// failure the change-log check exists to avoid.
    static let unrelatedChangesJSON = """
        {"methodResponses": [["Email/changes", {"accountId": "1", "oldState": "s1",
        "newState": "s3", "hasMoreChanges": false, "created": ["77"], "updated": [],
        "destroyed": []}, "c0"]]}
        """

    /// The change log naming the draft itself: another client wrote it.
    static let draftChangedJSON = """
        {"methodResponses": [["Email/changes", {"accountId": "1", "oldState": "s1",
        "newState": "s3", "hasMoreChanges": false, "created": [], "updated": ["42"],
        "destroyed": []}, "c0"]]}
        """
}

/// No address book, so a compose test never waits on permission.
private struct SilentContacts: ContactSource {
    func addresses(matching fragment: String) async -> [EmailAddress] { [] }
}

/// Two devices editing one draft.
///
/// `DraftUpdate` has carried an `ifInState` argument since it was written and
/// nothing ever passed one, so the second device's save landed on top of the
/// first's without a word to either. These tests pin the three things that has
/// to mean: the token is sent, an unrelated change to the account is *not* a
/// conflict, and a real one stops the save rather than resolving it.
@Suite("Draft conflicts")
@MainActor
struct DraftConflictTests {
    /// One scripted server per test, because what it answers depends on how
    /// many times it has been asked.
    private final class Server: Sendable {
        /// The `Email/changes` body to answer with, which is what decides
        /// whether the mismatch was about this draft.
        let changes: String
        /// How many `Email/set` updates have been asked for. The first is
        /// refused with `stateMismatch`; the rest succeed.
        private let updates = Mutex(0)

        init(changes: String) {
            self.changes = changes
        }

        func answer(to body: String) -> String {
            if body.contains("Email/get") { return ConflictFixtures.draftJSON }
            if body.contains("Identity/get") { return ConflictFixtures.identityJSON }
            if body.contains("Email/changes") { return changes }

            let attempt = updates.withLock { count -> Int in
                count += 1

                return count
            }

            return attempt == 1 ? ConflictFixtures.stateMismatchJSON : ConflictFixtures.setJSON
        }
    }

    private static func transport(_ server: Server) -> MockTransport {
        MockTransport { request in
            guard request.url?.path().contains(".well-known") == false else {
                return (
                    Data(ConflictFixtures.sessionJSON.utf8), MockTransport.response(for: request)
                )
            }

            let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""

            return (Data(server.answer(to: body).utf8), MockTransport.response(for: request))
        }
    }

    private static func model(_ transport: MockTransport) -> ComposeModel {
        ComposeModel(
            kind: .editDraft(emailID: "42"),
            accountKey: "nas.local/1",
            accountID: AccountID("1"),
            client: JMAPClient(
                discoveryURL: URL(string: "https://nas.local/.well-known/jmap")!,
                credential: .appPassword("plmail_test"),
                transport: transport),
            store: SyncStore(modelContainer: MailStack.makeContainer(inMemory: true)),
            outbox: Outbox(serverID: "test-\(UUID().uuidString)"),
            contacts: SilentContacts()
        )
    }

    /// Every `Email/set` argument object the composer sent, oldest first.
    private static func updates(_ transport: MockTransport) -> [[String: Any]] {
        transport.recorded.compactMap { recorded -> [String: Any]? in
            guard let body = recorded.body,
                let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                let calls = json["methodCalls"] as? [[Any]],
                let call = calls.first,
                call.first as? String == "Email/set",
                let arguments = call.dropFirst().first as? [String: Any],
                arguments["update"] != nil
            else { return nil }

            return arguments
        }
    }

    // MARK: -

    @Test("A draft save is conditional on the state the draft was read at")
    func theTokenIsSent() async throws {
        let transport = Self.transport(Server(changes: ConflictFixtures.unrelatedChangesJSON))
        let model = Self.model(transport)

        await model.load()
        model.subject = "Quarterly numbers, revised"
        await model.saveDraft()

        let first = try #require(Self.updates(transport).first)

        #expect(first["ifInState"] as? String == "s1")
    }

    /// The false positive, and the reason this is not a bare passthrough of the
    /// server's refusal. `ifInState` is checked against the **account's** email
    /// state, which every arriving message moves — so a composer left open on a
    /// busy inbox would otherwise announce a conflict that never happened.
    @Test("Mail arriving during a compose is not a conflict")
    func unrelatedChurnIsRetried() async throws {
        let transport = Self.transport(Server(changes: ConflictFixtures.unrelatedChangesJSON))
        let model = Self.model(transport)

        await model.load()
        model.subject = "Quarterly numbers, revised"
        await model.saveDraft()

        #expect(model.isDraftConflicted == false)

        if case .saved = model.saveState {
        } else {
            Issue.record("The save should have gone through: \(model.saveState)")
        }

        let sent = Self.updates(transport)

        // Two: the refused one, then the retry — and the retry carries the
        // state the change log advanced to, not the stale one.
        #expect(sent.count == 2)
        #expect(sent.last?["ifInState"] as? String == "s3")
    }

    @Test("A draft rewritten elsewhere stops the save and says so")
    func aRealConflictIsReported() async throws {
        let transport = Self.transport(Server(changes: ConflictFixtures.draftChangedJSON))
        let model = Self.model(transport)

        await model.load()
        model.subject = "Quarterly numbers, revised"
        await model.saveDraft()

        #expect(model.isDraftConflicted)
        // Exactly one attempt: the refused one. A retry here is the overwrite
        // the whole mechanism exists to prevent.
        #expect(Self.updates(transport).count == 1)

        if case .failed = model.saveState {
        } else {
            Issue.record("A conflict has to be visible: \(model.saveState)")
        }
    }

    /// Nothing typed is lost by the refusal, which is the point of stopping
    /// rather than discarding.
    @Test("The text stays in the composer through a conflict")
    func nothingIsDiscarded() async {
        let transport = Self.transport(Server(changes: ConflictFixtures.draftChangedJSON))
        let model = Self.model(transport)

        await model.load()
        model.subject = "Quarterly numbers, revised"
        await model.saveDraft()

        #expect(model.subject == "Quarterly numbers, revised")
    }

    /// A second save while conflicted must not reach the server at all, or the
    /// next keystroke resolves the question the user was asked.
    @Test("Autosave is held until the conflict is answered")
    func autosaveIsHeld() async {
        let transport = Self.transport(Server(changes: ConflictFixtures.draftChangedJSON))
        let model = Self.model(transport)

        await model.load()
        model.subject = "Quarterly numbers, revised"
        await model.saveDraft()

        model.subject = "Quarterly numbers, revised again"
        await model.saveDraft()

        #expect(Self.updates(transport).count == 1)
    }

    @Test("Keeping the local copy saves unconditionally, and only then")
    func keepingMineDropsTheCondition() async throws {
        let transport = Self.transport(Server(changes: ConflictFixtures.draftChangedJSON))
        let model = Self.model(transport)

        await model.load()
        model.subject = "Quarterly numbers, revised"
        await model.saveDraft()

        model.overwriteDraftElsewhere()

        // The save is a detached task, so wait for it rather than for a clock.
        for _ in 0..<200 where Self.updates(transport).count < 2 {
            await Task.yield()
        }

        let sent = Self.updates(transport)

        #expect(sent.count == 2)
        #expect(sent.last?["ifInState"] == nil, "An answered conflict is an unconditional save.")
        #expect(model.isDraftConflicted == false)
    }

    /// The other answer: leave the server's copy alone. It closes the composer
    /// and writes nothing, which is the only way to honour a newer version
    /// without merging.
    @Test("Closing without saving leaves the other device's copy untouched")
    func closingWritesNothing() async {
        let transport = Self.transport(Server(changes: ConflictFixtures.draftChangedJSON))
        let model = Self.model(transport)

        await model.load()
        model.subject = "Quarterly numbers, revised"
        await model.saveDraft()

        model.closeKeepingRemoteDraft()

        #expect(model.status == .closed)
        #expect(model.isDraftConflicted == false)
        #expect(Self.updates(transport).count == 1)
    }
}
