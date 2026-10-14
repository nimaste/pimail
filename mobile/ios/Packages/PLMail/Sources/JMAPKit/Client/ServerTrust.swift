import CryptoKit
import Foundation
import Security
import Synchronization

/// A SHA-256 fingerprint of a server's TLS public key.
///
/// The *key*, not the whole certificate: a certificate renewal that keeps the
/// same key — which is what `certbot renew` does by default — would otherwise
/// look identical to an attacker swapping the server out, and nagging the user
/// every ninety days teaches them to tap "trust" without reading.
public struct KeyFingerprint: Hashable, Sendable, CustomStringConvertible {
    public let bytes: Data

    public init(bytes: Data) {
        self.bytes = bytes
    }

    /// Uppercase hex in space-separated pairs, the way every other tool prints
    /// a fingerprint — so a user can compare it against `openssl` output
    /// without transcribing anything.
    public var description: String {
        bytes.map { String(format: "%02X", $0) }
            .enumerated()
            .map { $0.offset > 0 && $0.offset % 2 == 0 ? " \($0.element)" : $0.element }
            .joined()
    }

    /// The compact form, for storage.
    public var hex: String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    public init?(hex: String) {
        var bytes = Data()
        var index = hex.startIndex

        while index < hex.endIndex {
            guard let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex),
                let byte = UInt8(hex[index..<next], radix: 16)
            else { return nil }

            bytes.append(byte)
            index = next
        }

        self.init(bytes: bytes)
    }

    static func of(_ certificate: SecCertificate) -> KeyFingerprint? {
        guard let key = SecCertificateCopyKey(certificate),
            let representation = SecKeyCopyExternalRepresentation(key, nil) as Data?
        else { return nil }

        return KeyFingerprint(bytes: Data(SHA256.hash(data: representation)))
    }
}

/// Decides whether to talk to a server whose certificate the system does not
/// trust.
///
/// plMail runs on machines people own: a NAS with a self-signed certificate, a
/// Tailscale node, a box behind a private CA. Refusing all of them makes the
/// app useless for its actual audience, and the usual shortcut —
/// `NSAllowsArbitraryLoads` — turns off validation for every connection
/// forever, including the ones that were fine.
///
/// So: trust-on-first-use, pinned to one key.
///
/// 1. System evaluation runs first. If it passes there is nothing to ask about.
/// 2. If it fails and nothing is pinned, the connection is refused and the
///    fingerprint is reported, so onboarding can show it and let the user
///    decide once.
/// 3. If it fails and the fingerprint matches the pin, it is allowed.
/// 4. If it fails and the fingerprint *differs* from the pin, it is refused —
///    permanently, and loudly. A changed key on a pinned server is the one
///    case that must never degrade back into a prompt, because a prompt is
///    exactly what an attacker needs.
public final class ServerTrust: NSObject, URLSessionDelegate, @unchecked Sendable {
    /// The fingerprint the user has already accepted, if any.
    public let pinned: KeyFingerprint?

    /// The fingerprint of the most recent rejected certificate, so onboarding
    /// can offer to pin it. Written from the URLSession delegate queue and read
    /// from the caller's, hence the mutex.
    private let observed = Mutex<KeyFingerprint?>(nil)

    public init(pinned: KeyFingerprint? = nil) {
        self.pinned = pinned
    }

    public var lastRejectedFingerprint: KeyFingerprint? {
        observed.withLock { $0 }
    }

    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler:
            @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?)
            -> Void
    ) {
        guard
            challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let trust = challenge.protectionSpace.serverTrust
        else {
            return completionHandler(.performDefaultHandling, nil)
        }

        if SecTrustEvaluateWithError(trust, nil) {
            return completionHandler(.performDefaultHandling, nil)
        }

        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
            let leaf = chain.first,
            let fingerprint = KeyFingerprint.of(leaf)
        else {
            return completionHandler(.cancelAuthenticationChallenge, nil)
        }

        observed.withLock { $0 = fingerprint }

        guard let pinned, pinned == fingerprint else {
            return completionHandler(.cancelAuthenticationChallenge, nil)
        }

        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
