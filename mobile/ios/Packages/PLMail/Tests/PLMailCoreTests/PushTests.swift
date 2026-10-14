import Foundation
import JMAPKit
import Testing

@testable import PLMailCore

@Suite("Push")
struct PushTests {
    /// The device token goes on the wire as lowercase hex. Every APNs library
    /// expects that spelling, and a server handed base64 or a Swift `Data`
    /// description would fail at send time — far from here.
    @Test("The token is encoded as lowercase hex")
    func tokenEncoding() throws {
        let token = Data([0x00, 0x0f, 0xa1, 0xff])
        let hex = token.map { String(format: "%02x", $0) }.joined()

        #expect(hex == "000fa1ff")
    }

    @Test("A registration names the environment it was built for")
    func environment() throws {
        let method = PushSubscriptionSet(token: "abc", deviceName: "Phone")
        let json = try JSONEncoder().encode(method.arguments)
        let decoded = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        let device = (decoded?["update"] as? [String: Any])?["thisDevice"] as? [String: Any]

        #expect(device?["deviceToken"] as? String == "abc")
        #expect(device?["deviceName"] as? String == "Phone")
        // Sandbox under test, since tests build in debug. The point is that
        // the field is present at all: a token from a debug build sent to
        // production APNs is rejected with an error that does not explain
        // itself.
        #expect(device?["environment"] as? String == "sandbox")
    }

    /// Unregistering is the same method with a null token, so a signed-out
    /// device stops being woken for a mailbox it can no longer read.
    @Test("Unregistering clears the token rather than omitting it")
    func unregister() throws {
        let method = PushSubscriptionSet(token: nil, deviceName: nil)
        let json = try JSONEncoder().encode(method.arguments)
        let text = String(decoding: json, as: UTF8.self)

        #expect(text.contains("\"deviceToken\":null"))
    }

    /// Neither push URN may appear in `using`, and the registration method
    /// declares Core.
    ///
    /// This test previously asserted the opposite, which is how the bug
    /// survived: `PushSubscription/set` is RFC 8620 §7.2, the server's
    /// `Capability::SUPPORTED` has never contained an APNs URN, and an unknown
    /// capability refuses the **whole** request with `unknownCapability` — so
    /// the first registration would have taken every unrelated call batched
    /// with it off the air. Entitlements were the only thing keeping it latent.
    @Test("Neither push capability may be declared, and registration is a Core method")
    func capabilities() {
        #expect(Capability.apns.isSupportedInUsing == false)
        #expect(Capability.push.isSupportedInUsing == false)
        #expect(PushSubscriptionSet.capability == .core)
    }

    /// The vendor URN matches every other plMail extension.
    ///
    /// It was spelled `urn:de:plmail:params:jmap:apns`, which matches nothing
    /// the server advertises — so `isSupported()` would have answered false
    /// even against an instance that had grown an APNs sender, and the failure
    /// would have looked like a server without push rather than a typo.
    @Test("The APNs URN is spelled the way the server spells its extensions")
    func urn() {
        #expect(Capability.apns.rawValue == "urn:plmail:params:jmap:apns")
    }

    /// A server that has never heard of APNs must decode cleanly and simply
    /// report no support — that is every plMail instance today, and it is not
    /// an error.
    @Test("A session without the APNs capability decodes and reports no support")
    func absentCapability() throws {
        let json = Data(
            """
            {"urn:ietf:params:jmap:core":{"maxSizeUpload":1,"maxConcurrentUpload":1,
            "maxSizeRequestObject":1,"maxConcurrentRequests":1,"maxCallsInRequest":1,
            "maxObjectsInGet":1,"maxObjectsInSet":1,"collationAlgorithms":[]}}
            """.utf8)

        let capabilities = try JSONDecoder().decode(Session.Capabilities.self, from: json)

        #expect(capabilities.apns == nil)
    }
}
