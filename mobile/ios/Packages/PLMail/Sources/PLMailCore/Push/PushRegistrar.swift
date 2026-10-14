import Foundation
import JMAPKit
import OSLog

/// Registering this device for push, and turning a push into a sync.
///
/// **What push actually delivers here.** Not the message. A payload carrying
/// mail would mean the server encrypting bodies for Apple to relay, and would
/// put a copy of someone's mail through a third party for no benefit — the app
/// can fetch it in one round trip once it knows to look. So the payload says
/// only *something changed on this account*, and the app does an ordinary
/// delta pull. That also means a dropped or coalesced push costs nothing but
/// latency: the next foreground catches up either way.
///
/// **Why this is only half a feature today.** plMail has no APNs sender, and
/// cannot have one without a key from a paid Apple developer account — a
/// self-hosted server has no Apple relationship of its own. So this registers
/// the token against a vendor endpoint that does not exist yet, notices the
/// 404, and stops. That is deliberate: the client half is testable now
/// (`xcrun simctl push`), and when the server side lands nothing here changes.
///
/// See `docs/PUSH.md` for the server-side ask.
public actor PushRegistrar {
    private let client: JMAPClient
    private let logger = Logger(subsystem: "de.plmail", category: "push")
    private var registeredToken: String?

    public init(client: JMAPClient) {
        self.client = client
    }

    /// Whether the server can accept a token at all.
    ///
    /// Read from the session's advertised capabilities rather than assumed, so
    /// an older server produces one clean "not supported" instead of a failed
    /// request every launch.
    public func isSupported() async -> Bool {
        guard let session = try? await client.session() else { return false }

        return session.capabilities.apns != nil
    }

    /// Hands the device token to the server.
    ///
    /// Idempotent on the token: iOS hands the same one back on every launch,
    /// and re-registering an unchanged token every time would be a pointless
    /// write to somebody's NAS a few times a day.
    public func register(token: Data, deviceName: String) async {
        let hex = token.map { String(format: "%02x", $0) }.joined()

        guard hex != registeredToken else { return }

        guard await isSupported() else {
            logger.info("Server does not advertise APNs push; skipping registration.")

            return
        }

        do {
            var builder = RequestBuilder(session: try await client.session())
            let set = builder.add(
                PushSubscriptionSet(token: hex, deviceName: deviceName))
            let results = try await client.send(builder)

            if let error = results.failure(of: set) { throw error }

            registeredToken = hex
            logger.info("Registered for push.")
        } catch {
            // Never fatal. Push is an optimisation over the refresh that
            // already happens; failing to register must not stop the app from
            // being a mail client.
            logger.error("Push registration failed: \(error, privacy: .public)")
        }
    }

    /// Forgets the token, so a signed-out device stops being woken for a
    /// mailbox it can no longer read.
    public func unregister() async {
        guard registeredToken != nil, await isSupported() else { return }

        do {
            var builder = RequestBuilder(session: try await client.session())
            _ = builder.add(PushSubscriptionSet(token: nil, deviceName: nil))
            _ = try await client.send(builder)
        } catch {
            logger.error("Push unregistration failed: \(error, privacy: .public)")
        }

        registeredToken = nil
    }
}

/// The vendor method that carries a device token.
///
/// Shaped like a JMAP `/set` so it reads the same as everything else in the
/// batch, and so the server can reuse its existing method dispatch.
public struct PushSubscriptionSet: JMAPMethod {
    public static let name = "PushSubscription/set"
    /// **Core, not `apns`.**
    ///
    /// `PushSubscription/set` is RFC 8620 §7.2, so the only URN the server
    /// will accept for it is `urn:ietf:params:jmap:core`. Declaring the vendor
    /// APNs URN instead put a capability the server has never heard of into
    /// `using`, and an unknown capability refuses the **entire** request — so
    /// the first push registration would have taken every other call in that
    /// batch down with it. It was latent only because entitlements gate push.
    public static let capability = Capability.core

    public struct Subscription: Encodable, Sendable {
        /// Hex, lowercase — what `didRegisterForRemoteNotificationsWithDeviceToken`
        /// hands over, and what every APNs library expects.
        public var deviceToken: String?
        public var deviceName: String?
        /// So the server can send to the right APNs environment. Getting this
        /// wrong is the classic push bug: a sandbox token sent to production
        /// APNs is rejected with a message that does not say why.
        public var environment: String

        private enum CodingKeys: String, CodingKey {
            case deviceToken, deviceName, environment
        }

        /// Hand-written for one reason: a nil token has to reach the server as
        /// an explicit `null`.
        ///
        /// Swift's synthesised encoding omits nil optionals entirely, which
        /// turned "forget this device" into "change nothing about this
        /// device" — a signed-out phone would have gone on being woken for a
        /// mailbox it could no longer read. In a JMAP `/set` patch, absent and
        /// null mean genuinely different things, and this is exactly the case
        /// where the difference bites.
        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)

            try container.encode(deviceToken, forKey: .deviceToken)
            try container.encode(deviceName, forKey: .deviceName)
            try container.encode(environment, forKey: .environment)
        }
    }

    public struct Arguments: Encodable, Sendable {
        public var update: [String: Subscription]
    }

    public struct Result: Decodable, Sendable {
        public var updated: [String: JSONValue]?
        public var notUpdated: [String: JSONValue]?
    }

    public var arguments: Arguments

    public init(token: String?, deviceName: String?) {
        arguments = Arguments(
            update: [
                "thisDevice": Subscription(
                    deviceToken: token,
                    deviceName: deviceName,
                    environment: Self.environment
                )
            ])
    }

    /// A debug build talks to APNs sandbox; a release build does not. There is
    /// no runtime way to ask which provisioning profile was used, so this is
    /// decided at compile time, which is the same thing the profile decides.
    static var environment: String {
        #if DEBUG
        "sandbox"
        #else
        "production"
        #endif
    }
}
