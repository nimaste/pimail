public import Foundation
public import JMAPKit

/// Everything needed to reach one plMail server: where it is, how to prove who
/// you are, and which certificate the user accepted.
///
/// This is the only state the app cannot rebuild from the server, which is why
/// it lives in the Keychain and everything else lives in a disposable cache.
public struct ServerConnection: Hashable, Sendable {
    public var address: ServerAddress
    public var credential: Credential

    /// Set only when the user explicitly trusted a certificate the system
    /// would not. See ``JMAPKit/ServerTrust``.
    public var pinnedFingerprint: KeyFingerprint?

    /// The address the server reports for itself, kept so the UI can show who
    /// is signed in without a round trip.
    public var username: String?

    public init(
        address: ServerAddress,
        credential: Credential,
        pinnedFingerprint: KeyFingerprint? = nil,
        username: String? = nil
    ) {
        self.address = address
        self.credential = credential
        self.pinnedFingerprint = pinnedFingerprint
        self.username = username
    }

    public var host: String { address.host }

    /// A ready-to-use client for this connection.
    public func makeClient() -> JMAPClient {
        JMAPClient(
            discoveryURL: address.sessionDiscoveryURL,
            credential: credential,
            transport: URLSessionTransport(
                host: host,
                trust: ServerTrust(pinned: pinnedFingerprint)
            )
        )
    }
}
