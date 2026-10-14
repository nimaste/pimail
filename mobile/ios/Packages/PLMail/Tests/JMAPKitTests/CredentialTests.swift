import Foundation
import Testing

@testable import JMAPKit

@Suite("Credential and trust")
struct CredentialTests {
    private var validSecret: String { "plmail_" + String(repeating: "ab", count: 32) }

    /// Checked locally so a secret that lost its last characters on the way
    /// through a clipboard says so at once, instead of after a slow round trip
    /// to a home server that then reports "unauthorised".
    @Test("a well-formed app password is recognised before any network call")
    func wellFormed() {
        #expect(Credential.appPassword(validSecret).isWellFormed)
    }

    @Test(
        "malformed secrets are rejected",
        arguments: [
            "",
            "plmail_",
            "plmail_tooshort",
            // Right length, missing prefix — the server would route this to
            // the JWT authenticator and fail with an unrelated message.
            String(repeating: "ab", count: 32),
            "plmail_" + String(repeating: "z", count: 64),
            "plmail_" + String(repeating: "a", count: 63),
        ]
    )
    func malformed(secret: String) {
        #expect(Credential.appPassword(secret).isWellFormed == false)
    }

    @Test("the header is Bearer, keeping the prefix the server routes on")
    func header() {
        #expect(Credential.appPassword(validSecret).authorizationHeader == "Bearer \(validSecret)")
    }

    /// The fingerprint is shown to a user who is expected to compare it with
    /// what their server reports, so the grouped form has to survive a round
    /// trip through storage unchanged.
    @Test("a fingerprint round-trips through its stored form")
    func fingerprintRoundTrip() throws {
        let original = KeyFingerprint(bytes: Data([0xDE, 0xAD, 0xBE, 0xEF, 0x01]))

        #expect(original.hex == "deadbeef01")
        #expect(original.description == "DEAD BEEF 01")
        #expect(KeyFingerprint(hex: original.hex) == original)
    }

    @Test("a malformed stored fingerprint is rejected rather than truncated")
    func malformedFingerprint() {
        #expect(KeyFingerprint(hex: "abc") == nil)
        #expect(KeyFingerprint(hex: "zz") == nil)
    }
}
