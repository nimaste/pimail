import Foundation
import JMAPKit
import OSLog

/// Enrolling this device by scanning a code.
///
/// The alternative is what this replaces: 71 characters of hex, shown once in
/// a web UI on a laptop, retyped on a phone keyboard. It is the worst moment
/// in onboarding and the one most likely to go wrong — as it did here, on a
/// German keymap that turns `_` into `?`.
///
/// The scanned code is **not** the app password. It is a short-lived
/// single-use pairing code that this exchanges for a freshly minted one, so a
/// QR left on a screen or caught in a screen-share cannot hand anyone
/// permanent access to a mailbox.
public struct DevicePairing: Sendable {
    /// What a `plmail://pair` link carries.
    public struct Request: Hashable, Sendable {
        public var address: ServerAddress
        public var code: String
    }

    public struct Paired: Hashable, Sendable {
        public var address: ServerAddress
        public var credential: Credential
        public var username: String
    }

    public enum Failure: Error, Sendable {
        case notAPairingLink
        case badServerAddress
        case codeRejected
        case unreachable(String)
        /// Kept distinct from `unreachable` so onboarding can offer the trust
        /// prompt instead of a dead end. A self-hosted server presenting a
        /// certificate this device has never seen is the normal case, not an
        /// error — and pairing is usually the very first request made to it.
        case untrustedCertificate(host: String, fingerprint: String)
    }

    private let logger = Logger(subsystem: "de.plmail", category: "pairing")

    public init() {}

    /// Reads a scanned string.
    ///
    /// Strict about the scheme and host: a camera pointed at the world will
    /// find plenty of QR codes, and the failure for "that was a URL to a
    /// website" has to be "that isn't a plMail code", not a network request to
    /// somebody else's server.
    public static func parse(_ scanned: String) throws(Failure) -> Request {
        // Newlines as well as spaces: `.whitespaces` alone leaves a trailing
        // newline in the string, which some scanners append and which breaks
        // the parse in a way that looks like a bad address.
        let trimmed = scanned.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let components = URLComponents(string: trimmed),
            components.scheme?.lowercased() == "plmail",
            components.host?.lowercased() == "pair"
        else {
            throw .notAPairingLink
        }

        let items = components.queryItems ?? []

        guard let host = items.first(where: { $0.name == "host" })?.value,
            let code = items.first(where: { $0.name == "code" })?.value,
            code.isEmpty == false
        else {
            throw .notAPairingLink
        }

        guard let address = try? ServerAddress.parse(host) else {
            throw .badServerAddress
        }

        return Request(address: address, code: code)
    }

    /// Exchanges the code for an app password.
    ///
    /// - Parameters:
    ///   - request: The host and code a scanned link carried.
    ///   - deviceName: What the credential is called in the user's
    ///     app-password list. The device's own name, so someone with four
    ///     phones can tell which one to revoke.
    ///   - transport: Carries the same trust policy the session probe will
    ///     use, so an unrecognised certificate surfaces as a question rather
    ///     than a dead end.
    /// - Returns: The address, the minted credential and whose mailbox it
    ///   reaches.
    /// - Throws: ``Failure`` — including
    ///   ``Failure/untrustedCertificate(host:fingerprint:)``, which the caller
    ///   is expected to turn into a trust prompt and retry.
    public func redeem(
        _ request: Request,
        deviceName: String,
        transport: any JMAPTransport
    ) async throws(Failure) -> Paired {
        let url = request.address.baseURL.appending(path: "device/pair")

        var post = URLRequest(url: url)
        post.httpMethod = "POST"
        post.setValue("application/json", forHTTPHeaderField: "Content-Type")
        post.setValue("application/json", forHTTPHeaderField: "Accept")
        post.httpBody = try? JSONEncoder().encode(
            Body(code: request.code, deviceName: deviceName))

        let data: Data
        let response: HTTPURLResponse

        do {
            (data, response) = try await transport.send(post)
        } catch JMAPError.untrustedCertificate(let host, let fingerprint) {
            throw .untrustedCertificate(host: host, fingerprint: fingerprint)
        } catch {
            logger.error("Pairing transport failed: \(error, privacy: .public)")

            throw .unreachable(request.address.host)
        }

        // A rejected code and a server that has no such endpoint both land
        // here, and both mean the same thing to the user: this code did not
        // work, get a fresh one.
        guard (200..<300).contains(response.statusCode),
            let paired = try? JSONDecoder().decode(Response.self, from: data)
        else {
            throw .codeRejected
        }

        return Paired(
            address: request.address,
            credential: .appPassword(paired.secret),
            username: paired.username
        )
    }

    private struct Body: Encodable {
        var code: String
        var deviceName: String
    }

    private struct Response: Decodable {
        var secret: String
        var username: String
    }
}

extension DevicePairing.Failure {
    /// What to put on screen. Deliberately never says whether the code was
    /// unknown, expired or already used — the server does not distinguish
    /// those either, because doing so would confirm which codes had been real.
    public var message: String {
        switch self {
        case .notAPairingLink:
            String(localized: "That isn't a plMail pairing code.", bundle: .module)
        case .badServerAddress:
            String(
                localized: "That code points at an address this app can't reach.", bundle: .module)
        case .codeRejected:
            String(
                localized:
                    "That code didn't work. They last two minutes and work once — show a new one.",
                bundle: .module)
        case .unreachable(let host):
            String(
                localized: "Can't reach \(host). Check you're on the same network as the server.",
                bundle: .module)
        case .untrustedCertificate(let host, _):
            "\(host) presented a certificate this device doesn't recognise."
        }
    }
}
