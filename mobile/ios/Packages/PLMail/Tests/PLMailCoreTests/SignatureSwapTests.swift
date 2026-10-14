import Foundation
import JMAPKit
import JMAPTestSupport
import Testing

@testable import PLMailCore

/// Signing a message, and re-signing it when the From changes.
///
/// **The extent is tracked in composer state, not marked up in the body**, and
/// these tests are what makes that safe. The server's `MailBodySanitizer` drops
/// every `data-` attribute from a stored draft body, so a marked block written
/// here comes back as a bare `<div>` — the round trip Android's `Signatures.kt`
/// documents does not happen on this server. A swap that re-scanned the body
/// for a marker would find nothing, and a swap that guessed where the old
/// signature ended would eat a paragraph.
@Suite("Signature swap")
@MainActor
struct SignatureSwapTests {
    /// The separator every mail client and every mailing list still recognises,
    /// which is what makes a quoting client trim it rather than quote it back.
    @Test("A signature is written as the Usenet separator block")
    func blockShape() {
        #expect(ComposeModel.signatureBlock("Ada\nLovelace") == "\n\n-- \nAda\nLovelace")
    }

    /// An empty signature produces **no block**, not an empty one: a stray
    /// separator under every message from that address is worse than none.
    @Test("An address that signs with nothing gets no block at all")
    func emptySignatureIsNoBlock() {
        #expect(ComposeModel.signatureBlock(nil) == nil)
        #expect(ComposeModel.signatureBlock("") == nil)
        #expect(ComposeModel.signatureBlock("   \n  ") == nil)
    }

    /// The emptiness rule the whole autosave depends on. Counting a signature
    /// as content meant opening a reply and changing your mind left a draft
    /// containing nothing but your own sign-off — once per abandoned composer,
    /// on every device.
    @Test("A body that is nothing but the signature is still empty")
    func signatureAloneIsBlank() {
        let block = ComposeModel.signatureBlock("Ada Lovelace")

        #expect(ComposeModel.isBlank("\n\n-- \nAda Lovelace", ignoring: block))
        #expect(
            ComposeModel.isBlank("Here they are.\n\n-- \nAda Lovelace", ignoring: block) == false)
    }

    /// A rich editor emits a non-breaking space for a line somebody backspaced
    /// through, and treating that as content is how an empty composer became a
    /// draft.
    @Test("A backspaced line is not content")
    func nonBreakingSpaceIsBlank() {
        #expect(ComposeModel.isBlank("\u{00A0}\n\u{00A0}", ignoring: nil))
    }
}

/// The same rules, driven through a live composer.
///
/// Everything above is arithmetic on strings. This is the part that has to hold
/// against an `AttributedString` somebody has been typing into.
@Suite("Signature swap in a composer")
@MainActor
struct SignatureSwapInComposerTests {
    private static let sessionJSON = """
        {
          "capabilities": {
            "urn:ietf:params:jmap:core": {
              "maxSizeUpload": 50000000, "maxConcurrentUpload": 4,
              "maxSizeRequestObject": 10000000, "maxConcurrentRequests": 4,
              "maxCallsInRequest": 32, "maxObjectsInGet": 500, "maxObjectsInSet": 500,
              "collationAlgorithms": ["i;unicode-casemap"]
            }
          },
          "accounts": { "1": { "name": "me@example.org", "isPersonal": true,
            "isReadOnly": false, "accountCapabilities": {} } },
          "primaryAccounts": { "urn:ietf:params:jmap:mail": "1" },
          "username": "me@example.org",
          "apiUrl": "https://nas.local/jmap/api",
          "downloadUrl": "https://nas.local/jmap/download/{accountId}/{blobId}/{name}",
          "uploadUrl": "https://nas.local/jmap/upload/{accountId}",
          "eventSourceUrl": "https://nas.local/jmap/eventsource",
          "state": "s0"
        }
        """

    /// Two identities that sign differently, in one account, already in the
    /// store — the state a composer opens into.
    private static func model() async throws -> ComposeModel {
        let store = SyncStore(modelContainer: MailStack.makeContainer(inMemory: true))
        let session = try JSONDecoder().decode(Session.self, from: Data(sessionJSON.utf8))

        try await store.syncAccounts(session: session, serverID: "nas.local")

        var work = Identity(id: IdentityID(rawValue: "10"))
        work.name = "Ada at work"
        work.email = "ada@work.example"
        work.textSignature = "Ada Lovelace\nAnalytical Engines Ltd"

        var home = Identity(id: IdentityID(rawValue: "11"))
        home.name = "Ada"
        home.email = "ada@home.example"
        home.textSignature = "— Ada"

        try await store.replaceIdentities([work, home], accountKey: "nas.local/1")

        return ComposeModel(
            kind: .new,
            accountKey: "nas.local/1",
            accountID: AccountID("1"),
            client: JMAPClient(
                discoveryURL: URL(string: "https://nas.local/.well-known/jmap")!,
                credential: .appPassword("plmail_test"),
                transport: MockTransport(body: Data("{}".utf8), statusCode: 500)),
            store: store,
            outbox: Outbox(serverID: "sig-\(UUID().uuidString)"),
            contacts: SilentContacts()
        )
    }

    private static func text(_ model: ComposeModel) -> String {
        String(model.body.characters)
    }

    @Test("The selected identity's signature is on the message")
    func firstIdentitySigns() async throws {
        let model = try await Self.model()

        await model.load()

        let signature = try #require(model.selectedIdentity?.textSignature)

        #expect(Self.text(model).hasSuffix("-- \n" + signature))
    }

    /// **The failure this replaces.** Before, `hasSignature` applied a signature
    /// once and never again, so changing From left the previous address's
    /// sign-off on the message — a work signature under a mail sent from home.
    @Test("Changing From replaces the signature rather than stacking one on")
    func swapReplaces() async throws {
        let model = try await Self.model()

        await model.load()

        let original = try #require(model.selectedIdentity)
        let other = try #require(model.identities.first { $0.id != original.id })

        model.selectIdentity(other)

        let body = Self.text(model)

        #expect(body.hasSuffix("-- \n" + (try #require(other.textSignature))))
        #expect(
            body.contains(try #require(original.textSignature)) == false,
            "the old one is gone, not buried")
        #expect(body.components(separatedBy: "-- \n").count == 2, "exactly one sign-off")
    }

    /// The whole reason the extent is tracked: a swap must touch the signature
    /// and nothing else.
    @Test("Changing From leaves what was typed exactly where it was")
    func swapKeepsTypedText() async throws {
        let model = try await Self.model()

        await model.load()

        // Typed *before* the signature, which is where the cursor actually is.
        model.body = AttributedString("Here they are.") + model.body

        let original = try #require(model.selectedIdentity)
        let other = try #require(model.identities.first { $0.id != original.id })

        model.selectIdentity(other)

        #expect(Self.text(model).hasPrefix("Here they are."))
        #expect(Self.text(model).hasSuffix("-- \n" + (try #require(other.textSignature))))
    }

    /// A user who edited their own sign-off has made it theirs. Deleting the
    /// last N characters of whatever is there instead is how a From swap eats a
    /// paragraph.
    @Test("An edited signature is not silently deleted by a swap")
    func editedSignatureSurvives() async throws {
        let model = try await Self.model()

        await model.load()

        let original = try #require(model.selectedIdentity)

        model.body.append(AttributedString(" (mobile)"))

        let other = try #require(model.identities.first { $0.id != original.id })

        model.selectIdentity(other)

        // The old text is left alone — the new block is appended rather than
        // written over something the app no longer recognises.
        let edited = try #require(original.textSignature) + " (mobile)"

        #expect(Self.text(model).contains(edited))
    }

    /// A draft already contains whatever signature it was written with, there
    /// is no marker left in it to scope to, and appending again would stack two
    /// sign-offs.
    @Test("A reopened draft is never re-signed")
    func reopenedDraftIsLeftAlone() async throws {
        let store = SyncStore(modelContainer: MailStack.makeContainer(inMemory: true))
        let model = ComposeModel(
            kind: .editDraft(emailID: "42"),
            accountKey: "nas.local/1",
            accountID: AccountID("1"),
            client: JMAPClient(
                discoveryURL: URL(string: "https://nas.local/.well-known/jmap")!,
                credential: .appPassword("plmail_test"),
                transport: MockTransport(body: Data("{}".utf8), statusCode: 500)),
            store: store,
            outbox: Outbox(serverID: "sig-\(UUID().uuidString)"),
            contacts: SilentContacts()
        )

        model.body = AttributedString("Already written.\n\n-- \nAda")

        await model.load()

        #expect(Self.text(model).components(separatedBy: "-- \n").count == 2)
    }
}

/// A source that never answers, so a suite about signatures cannot ask the
/// device address book for permission.
private struct SilentContacts: ContactSource {
    func addresses(matching fragment: String) async -> [EmailAddress] { [] }
}
