import Foundation
import Testing

@testable import JMAPKit

/// What an `Identity/set` patch actually puts on the wire.
///
/// The whole feature rests on one distinction the server makes and Swift's
/// synthesised `Encodable` cannot: **omitting `htmlSignature` means "leave the
/// signature alone" and sending it empty means "this address signs with
/// nothing".** A synthesised encoder drops nil optionals, which collapses the
/// two — and collapses them in the direction that silently fails, because
/// clearing a signature would look like it worked and change nothing.
@Suite("Identity/set signatures")
struct IdentitySignatureTests {
    private func encoded(_ patch: IdentitySet.IdentityPatch) throws -> [String: Any] {
        let data = try JSONEncoder().encode(patch)
        let object = try JSONSerialization.jsonObject(with: data)

        return try #require(object as? [String: Any])
    }

    @Test("An explicitly empty signature is written, not omitted")
    func emptySignatureIsAStatement() throws {
        let json = try encoded(IdentitySet.IdentityPatch(htmlSignature: ""))

        #expect(json.keys.contains("htmlSignature"))
        #expect(json["htmlSignature"] as? String == "")
    }

    /// The other half of the same rule, and the one a rename depends on.
    @Test("A patch that says nothing about the signature carries no signature key")
    func omittedSignatureIsAbsent() throws {
        let json = try encoded(IdentitySet.IdentityPatch(name: "Ada"))

        #expect(json["name"] as? String == "Ada")
        #expect(json.keys.contains("htmlSignature") == false)
        #expect(json.keys.contains("textSignature") == false)
    }

    /// Renaming must not clear a signature the user never touched.
    @Test("A rename sends only the name")
    func renameSendsOnlyTheName() throws {
        let method = IdentitySet.rename(
            IdentityID(rawValue: "7"), to: "Ada", accountID: AccountID(rawValue: "1"))
        let patch = try #require(method.arguments.update[IdentityID(rawValue: "7")])
        let json = try encoded(patch)

        #expect(json.count == 1)
        #expect(json["name"] as? String == "Ada")
    }

    /// The server takes `htmlSignature` and ignores `textSignature` when both
    /// arrive, so sending both would silently discard one of them. This type
    /// never sends both.
    @Test("htmlSignature wins, and the text form is not sent beside it")
    func htmlWinsOverText() throws {
        let json = try encoded(
            IdentitySet.IdentityPatch(htmlSignature: "<p>Ada</p>", textSignature: "Ada"))

        #expect(json["htmlSignature"] as? String == "<p>Ada</p>")
        #expect(json.keys.contains("textSignature") == false)
    }

    @Test("A plain-text signature is sent as textSignature for the server to escape")
    func textOnlyIsSentAsText() throws {
        let json = try encoded(IdentitySet.IdentityPatch(textSignature: "Ada\n<b>"))

        #expect(json["textSignature"] as? String == "Ada\n<b>")
        #expect(json.keys.contains("htmlSignature") == false)
    }

    @Test("The clearing helper sends an empty htmlSignature")
    func clearingHelperSendsEmptyHTML() throws {
        let method = IdentitySet.setHTMLSignature(
            "", for: IdentityID(rawValue: "7"), accountID: AccountID(rawValue: "1"))
        let patch = try #require(method.arguments.update[IdentityID(rawValue: "7")])

        #expect(try encoded(patch)["htmlSignature"] as? String == "")
    }
}
