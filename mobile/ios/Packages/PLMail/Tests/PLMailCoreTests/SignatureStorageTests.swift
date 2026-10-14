import Foundation
import JMAPKit
import Testing

@testable import PLMailCore

/// A signature has to survive the round trip through the cache.
///
/// The cache is disposable and the signature is not lost when it goes — the
/// server holds it — but a settings screen reads the *stored* copy, and a store
/// that flattened an explicitly empty signature into nil would offer to
/// "inherit the account's" on an address that has already said it does not.
@Suite("Signature storage")
struct SignatureStorageTests {
    private func makeStore() -> SyncStore {
        SyncStore(modelContainer: MailStack.makeContainer(inMemory: true))
    }

    private func identity(
        _ email: String, html: String?, text: String? = nil
    ) -> Identity {
        var identity = Identity(id: IdentityID(rawValue: "id-1"))
        identity.email = email
        identity.htmlSignature = html
        identity.textSignature = text

        return identity
    }

    @Test("An HTML signature survives the round trip through the store")
    func htmlSignatureIsPersisted() async throws {
        let store = makeStore()

        try await store.replaceIdentities(
            [identity("ada@example.test", html: "<p>Ada</p>", text: "Ada")], accountKey: "a")

        let stored = try #require(try await store.identities(accountKey: "a").first)

        #expect(stored.htmlSignature == "<p>Ada</p>")
        #expect(stored.textSignature == "Ada")
        #expect(stored.hasStoredSignature)
    }

    /// The distinction the whole feature rests on, at the storage layer: empty
    /// is a stored statement and must not become nil on the way in.
    @Test("An explicitly empty signature is stored as empty, not as nothing")
    func emptySignatureIsStoredAsAStatement() async throws {
        let store = makeStore()

        try await store.replaceIdentities(
            [identity("ada@example.test", html: "")], accountKey: "a")

        let stored = try #require(try await store.identities(accountKey: "a").first)

        #expect(stored.htmlSignature == "")
        #expect(stored.htmlSignature != nil)
        #expect(stored.hasStoredSignature == false)
    }

    @Test("An address the server said nothing about keeps nothing")
    func absentSignatureStaysNil() async throws {
        let store = makeStore()

        try await store.replaceIdentities(
            [identity("ada@example.test", html: nil)], accountKey: "a")

        #expect(try await store.identities(accountKey: "a").first?.htmlSignature == nil)
    }

    /// Whitespace is nothing: a signature that is one blank line would append
    /// a blank line to every message sent from the address.
    @Test(
        "A signature with nothing in it does not count as one",
        arguments: [nil, "", "   ", "\n\n"])
    func blankSignaturesDoNotCount(html: String?) {
        var snapshot = IdentitySnapshot(id: IdentityID(rawValue: "1"), email: "a@b.test")
        snapshot.htmlSignature = html

        #expect(snapshot.hasStoredSignature == false)
    }
}

/// Deciding whether a plain-text box may edit a stored signature.
///
/// Guessing wrong in one direction refuses to edit something that could have
/// been edited; guessing wrong in the other silently destroys a signature
/// somebody built in the web interface, on a Save they pressed to change a
/// name. The asymmetry is why the test list leans on the second.
@Suite("Signature text")
struct SignatureTextTests {
    @Test(
        "Line breaks and paragraphs are lossless in a plain-text field",
        arguments: [nil, "", "Ada", "Ada<br>Lovelace", "<p>Ada</p><p>Lovelace</p>", "a<br />b"])
    func plainEquivalents(html: String?) {
        #expect(SignatureText.isPlainTextEquivalent(html))
    }

    @Test(
        "Anything carrying formatting is not editable here",
        arguments: [
            "<a href=\"https://example.test\">Ada</a>",
            "<img src=\"logo.png\">",
            "<b>Ada</b>",
            "<p style=\"color:red\">Ada</p>",
            "<table><tr><td>Ada</td></tr></table>",
        ])
    func richSignaturesAreRefused(html: String) {
        #expect(SignatureText.isPlainTextEquivalent(html) == false)
    }

    @Test("Breaks become newlines and entities become their characters")
    func flattening() {
        #expect(SignatureText.plainText(fromHTML: "Ada<br>Lovelace") == "Ada\nLovelace")
        #expect(SignatureText.plainText(fromHTML: "&lt;b&gt;") == "<b>")
        #expect(SignatureText.plainText(fromHTML: nil).isEmpty)
    }

    /// Decoding the ampersand last is what stops a signature that really
    /// contains the text `&lt;` from decoding twice into `<`.
    @Test("A double-escaped entity decodes once")
    func ampersandIsDecodedLast() {
        #expect(SignatureText.plainText(fromHTML: "&amp;lt;") == "&lt;")
    }

    @Test("Whitespace-only counts as blank", arguments: ["", " ", "\n", "\t "])
    func blankness(text: String) {
        #expect(SignatureText.isBlank(text))
    }
}
