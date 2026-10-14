import Foundation
import Testing

@testable import PLMailCore

@Suite("ServerAddress")
struct ServerAddressTests {
    @Test(
        "what people actually type normalises to a base URL",
        arguments: [
            ("nas.local", "https://nas.local"),
            ("  nas.local  ", "https://nas.local"),
            ("NAS.local", "https://nas.local"),
            ("https://mail.example.com", "https://mail.example.com"),
            ("https://mail.example.com/", "https://mail.example.com"),
            ("https://mail.example.com///", "https://mail.example.com"),
            ("mail.example.com:8443", "https://mail.example.com:8443"),
            ("192.168.1.5:8080", "https://192.168.1.5:8080"),
            ("http://192.168.1.5:8080", "http://192.168.1.5:8080"),
            // Reverse-proxied under a subpath — kept, because discarding it
            // sends every request to the wrong place.
            ("https://example.com/plmail", "https://example.com/plmail"),
            ("https://example.com/plmail/", "https://example.com/plmail"),
        ]
    )
    func normalises(input: String, expected: String) throws {
        let address = try ServerAddress.parse(input)

        #expect(address.baseURL.absoluteString == expected)
    }

    /// Downgrading someone's mail server to cleartext is not something to get
    /// by omission — `http` has to be typed.
    @Test("a missing scheme infers https, never http")
    func inferredSchemeIsSecure() throws {
        #expect(try ServerAddress.parse("nas.local").isCleartext == false)
        #expect(try ServerAddress.parse("http://nas.local").isCleartext)
    }

    /// `user:password@` survives into a base URL, unlike the query and
    /// fragment this parser already cleared — so an accepted one would be
    /// baked into every request the app ever makes against this server and
    /// into the Keychain metadata beside the app password.
    ///
    /// Refused rather than stripped. Stripping is quieter but leaves the user
    /// believing they supplied a credential when they did not, and what gets
    /// pasted here is almost always the account password rather than the app
    /// password this app asks for.
    @Test(
        "an address carrying credentials is refused, not quietly cleaned",
        arguments: [
            "https://me:hunter2@nas.local",
            "http://me:hunter2@nas.local",
            // No scheme typed, so `https://` is prefixed first — the check has
            // to run after that or this one slips through.
            "me:hunter2@nas.local",
            // A username with no password is the same disclosure.
            "https://me@nas.local",
        ]
    )
    func credentialsAreRefused(input: String) {
        #expect(throws: ServerAddress.ParseError.credentialsInAddress) {
            try ServerAddress.parse(input)
        }
    }

    /// The neighbouring case, so the refusal above cannot be implemented by
    /// rejecting every `@`: a mail-shaped host is not a credential.
    @Test("an ordinary address with no userinfo still parses")
    func withoutCredentials() throws {
        #expect(
            try ServerAddress.parse("https://nas.local/plmail").baseURL.absoluteString
                == "https://nas.local/plmail")
    }

    @Test("discovery resolves relative to the base, subpath included")
    func discoveryURL() throws {
        #expect(
            try ServerAddress.parse("nas.local").sessionDiscoveryURL.absoluteString
                == "https://nas.local/.well-known/jmap"
        )
        #expect(
            try ServerAddress.parse("https://example.com/plmail").sessionDiscoveryURL.absoluteString
                == "https://example.com/plmail/.well-known/jmap"
        )
    }

    /// A pasted address can carry a query or fragment from wherever it was
    /// copied. Keeping either would attach it to every request.
    @Test("query and fragment are dropped")
    func stripsQueryAndFragment() throws {
        let address = try ServerAddress.parse("https://nas.local/plmail?token=abc#top")

        #expect(address.baseURL.absoluteString == "https://nas.local/plmail")
    }

    @Test("failures say which part is wrong")
    func failures() {
        #expect(throws: ServerAddress.ParseError.empty) {
            try ServerAddress.parse("   ")
        }
        #expect(throws: ServerAddress.ParseError.unsupportedScheme("ftp")) {
            try ServerAddress.parse("ftp://nas.local")
        }
        #expect(throws: ServerAddress.ParseError.missingHost) {
            try ServerAddress.parse("https://")
        }
    }
}
