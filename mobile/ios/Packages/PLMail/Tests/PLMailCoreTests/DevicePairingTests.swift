import Foundation
import Testing

@testable import PLMailCore

/// A camera pointed at the world finds plenty of QR codes. Everything here is
/// about the ones that are not pairing codes: none of them may turn into a
/// network request, and none may enrol the device anywhere.
@Suite("Device pairing")
struct DevicePairingTests {
    @Test("a well-formed link yields the host and the code")
    func parses() throws {
        let request = try DevicePairing.parse(
            "plmail://pair?host=https%3A%2F%2Fnas.local&code=abc123")

        #expect(request.address.baseURL.absoluteString == "https://nas.local")
        #expect(request.code == "abc123")
    }

    @Test("the scheme is checked, so somebody else's QR is not a pairing code")
    func wrongScheme() {
        for scanned in [
            "https://evil.example/pair?host=https://evil.example&code=x",
            "otpauth://totp/plMail?secret=ABC",
            "WIFI:S=cafe;T=WPA;P=hunter2;;",
            "just some text",
            "",
        ] {
            #expect(throws: DevicePairing.Failure.self) {
                try DevicePairing.parse(scanned)
            }
        }
    }

    /// The right scheme with the wrong action is still not a pairing code —
    /// otherwise any future plmail:// link would be one.
    @Test("the host segment has to be pair")
    func wrongAction() {
        #expect(throws: DevicePairing.Failure.self) {
            try DevicePairing.parse("plmail://open?host=https%3A%2F%2Fnas.local&code=abc")
        }
    }

    @Test(
        "a link missing either half is refused",
        arguments: [
            "plmail://pair?host=https%3A%2F%2Fnas.local",
            "plmail://pair?code=abc123",
            "plmail://pair?host=https%3A%2F%2Fnas.local&code=",
            "plmail://pair",
        ]
    )
    func incomplete(scanned: String) {
        #expect(throws: DevicePairing.Failure.self) {
            try DevicePairing.parse(scanned)
        }
    }

    /// A code whose host is not something this app will talk to has to fail as
    /// a bad address rather than being handed to the transport.
    @Test("an unusable host is rejected before any request")
    func badHost() {
        #expect(throws: DevicePairing.Failure.self) {
            try DevicePairing.parse("plmail://pair?host=ftp%3A%2F%2Fnas.local&code=abc")
        }
    }

    @Test("surrounding whitespace from a scanner is tolerated")
    func trimsWhitespace() throws {
        let request = try DevicePairing.parse(
            "  plmail://pair?host=https%3A%2F%2Fnas.local&code=abc123\n")

        #expect(request.code == "abc123")
    }

    /// The failure copy must never say *why* a code did not work. The server
    /// answers unknown, expired and already-used identically, because telling
    /// them apart confirms which codes had once been real; the client saying it
    /// would give that away again.
    @Test("the rejection message does not distinguish expired from unknown")
    func opaqueRejection() {
        let message = DevicePairing.Failure.codeRejected.message

        #expect(message.localizedCaseInsensitiveContains("expired") == false)
        #expect(message.localizedCaseInsensitiveContains("unknown") == false)
        #expect(message.localizedCaseInsensitiveContains("already") == false)
    }
}
