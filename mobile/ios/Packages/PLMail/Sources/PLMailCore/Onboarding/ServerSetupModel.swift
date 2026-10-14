import Foundation
import JMAPKit
import Observation

/// Drives connecting to a server for the first time.
///
/// Deliberately not in the view: the interesting behaviour here is the state
/// machine — what counts as a certificate the user should be asked about, what
/// gets shown before anything is written to the Keychain — and none of that
/// needs SwiftUI to be tested.
@MainActor
@Observable
public final class ServerSetupModel {
    public enum Phase: Equatable, Sendable {
        case editing
        case connecting
        /// Verified. Nothing is saved until the user confirms — they should be
        /// able to see whose mailbox they just reached before committing to it.
        case confirming(username: String, accounts: [String])
        /// The system rejected the certificate. The fingerprint is shown so it
        /// can be compared against the server before trusting it.
        case untrusted(host: String, fingerprint: KeyFingerprint)
        case failed(message: String)
    }

    public var addressText: String = ""
    public var secretText: String = ""
    public private(set) var phase: Phase = .editing

    private var verifiedConnection: ServerConnection?
    /// A scanned pairing code waiting to be exchanged.
    ///
    /// Held rather than redeemed on the spot because the exchange has to
    /// happen *inside* the connect flow: a self-hosted server usually presents
    /// a certificate this device has never seen, and the request that trips
    /// over that has to be one the trust prompt can retry. Redeeming before
    /// `attempt` would hit the same wall with nowhere to put the question.
    private var pendingPairingCode: String?
    /// What the minted credential will be called in the user's app-password
    /// list. Passed in from the view rather than read here: this module builds
    /// for macOS so the test suite can run without a simulator, and `UIDevice`
    /// does not exist there.
    private var pendingDeviceName = "Paired device"
    private let store: CredentialStore
    private let onConnected: @MainActor (ServerConnection) -> Void

    public init(
        store: CredentialStore = CredentialStore(),
        address: String = "",
        onConnected: @escaping @MainActor (ServerConnection) -> Void
    ) {
        self.store = store
        addressText = address
        self.onConnected = onConnected
    }

    public var isBusy: Bool { phase == .connecting }

    /// Whether the fields are worth sending. Checked locally so an obviously
    /// mistyped secret says so immediately instead of after a round trip to a
    /// server that may be slow.
    public var canConnect: Bool {
        addressText.trimmingCharacters(in: .whitespaces).isEmpty == false
            && secretText.trimmingCharacters(in: .whitespaces).isEmpty == false
            && isBusy == false
    }

    /// Whether the typed address would send the app password in the clear.
    ///
    /// Read live, from the address field, **before** ``connect()`` can be
    /// pressed. `ServerAddress.isCleartext` already existed and was consumed
    /// only by the diagnostics screen — which is reachable only once the
    /// secret has already crossed the wire, so the warning arrived after the
    /// thing it warns about. A 71-character app password sent over `http` on a
    /// café network cannot be un-sent, and the user cannot tell that it was.
    ///
    /// False while the address is unparseable: a warning shown under text
    /// somebody is halfway through typing teaches them to ignore it.
    public var warnsAboutCleartext: Bool {
        (try? ServerAddress.parse(addressText))?.isCleartext ?? false
    }

    /// Whether the secret is the right shape. Not an error while typing — only
    /// worth surfacing once they have stopped.
    public var secretLooksWrong: Bool {
        let trimmed = secretText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return false }
        return Credential.appPassword(trimmed).isWellFormed == false
    }

    // MARK: - Actions

    public func connect() async {
        await attempt(pinning: nil)
    }

    /// Enrols this device from a scanned pairing code.
    ///
    /// Fills the address and then runs the ordinary connect, rather than
    /// taking a shortcut past it. Everything that flow does still has to
    /// happen — the certificate question, the session probe, showing which
    /// mailbox was reached before anything is written — and a second route to
    /// a saved credential would be a second route to get those wrong.
    public func pair(with scanned: String, deviceName: String) async {
        do {
            let request = try DevicePairing.parse(scanned)

            addressText = request.address.baseURL.absoluteString
            pendingPairingCode = request.code
            pendingDeviceName = deviceName
            secretText = ""

            await attempt(pinning: nil)
        } catch let failure as DevicePairing.Failure {
            phase = .failed(message: failure.message)
        } catch {
            phase = .failed(
                message: String(localized: "That pairing code couldn't be read.", bundle: .module))
        }
    }

    /// Retries, trusting the certificate the user was just shown.
    public func trustAndRetry() async {
        guard case .untrusted(_, let fingerprint) = phase else { return }
        await attempt(pinning: fingerprint)
    }

    /// Commits the verified connection to the Keychain.
    public func save() {
        guard let verifiedConnection else { return }

        do {
            try store.save(verifiedConnection)
            onConnected(verifiedConnection)
        } catch {
            phase = .failed(
                message: String(
                    localized: "Couldn't save to the keychain: \(String(describing: error))",
                    bundle: .module))
        }
    }

    public func editAgain() {
        verifiedConnection = nil
        phase = .editing
    }

    // MARK: - Verification

    private func attempt(pinning fingerprint: KeyFingerprint?) async {
        phase = .connecting

        let trimmedSecret = secretText.trimmingCharacters(in: .whitespacesAndNewlines)

        let address: ServerAddress
        do {
            address = try ServerAddress.parse(addressText)
        } catch {
            phase = .failed(message: Self.describe(addressError: error))
            return
        }

        // The exchange runs here, under the same trust policy the session probe
        // will use, so an unrecognised certificate surfaces as the question the
        // user can answer rather than as a dead end.
        var secret = trimmedSecret

        if let code = pendingPairingCode {
            do {
                let paired = try await DevicePairing().redeem(
                    DevicePairing.Request(address: address, code: code),
                    deviceName: pendingDeviceName,
                    transport: URLSessionTransport(
                        host: address.host,
                        trust: ServerTrust(pinned: fingerprint)
                    )
                )

                guard case .appPassword(let issued) = paired.credential else { return }

                secret = issued
                secretText = issued
                // Burned only once it has been exchanged: a certificate prompt
                // between here and there has to be able to retry with the same
                // code, which is still unused.
                pendingPairingCode = nil
            } catch DevicePairing.Failure.untrustedCertificate(let host, let fingerprint) {
                phase =
                    KeyFingerprint(hex: fingerprint).map { .untrusted(host: host, fingerprint: $0) }
                    ?? .failed(message: "\(host) presented a certificate that couldn't be read.")

                return
            } catch let failure as DevicePairing.Failure {
                phase = .failed(message: failure.message)

                return
            } catch {
                phase = .failed(
                    message: String(
                        localized: "That pairing code didn't work.", bundle: .module))

                return
            }
        }

        let connection = ServerConnection(
            address: address,
            credential: .appPassword(secret),
            pinnedFingerprint: fingerprint
        )

        do {
            let session = try await connection.makeClient().verify()

            var verified = connection
            verified.username = session.username
            verifiedConnection = verified

            phase = .confirming(
                username: session.username,
                // Named, even when the server didn't name it. This list is
                // the "check this is the right mailbox" step, and a blank
                // row there is the one place a blank row is least
                // affordable — it is the moment someone is being asked to
                // confirm something.
                accounts: session.orderedAccounts.map { entry in
                    let name = entry.account.name.trimmingCharacters(
                        in: .whitespacesAndNewlines)

                    return name.isEmpty ? "Mailbox \(entry.id.rawValue)" : name
                }
            )
        } catch let error as JMAPError {
            phase = Self.phase(for: error, host: address.host)
        } catch {
            phase = .failed(
                message: String(
                    localized: "Something went wrong: \(error.localizedDescription)",
                    bundle: .module))
        }
    }

    /// Errors name the cause and, where possible, what to do about it — the
    /// register the server's own UI uses. Never "Error".
    private static func phase(for error: JMAPError, host: String) -> Phase {
        switch error {
        case .untrustedCertificate(let host, let fingerprint):
            if let fingerprint = KeyFingerprint(hex: fingerprint) {
                return .untrusted(host: host, fingerprint: fingerprint)
            }
            return .failed(message: "\(host) presented a certificate that couldn't be read.")

        case .notAuthenticated:
            return .failed(
                message: """
                    \(host) rejected that app password. It may have been revoked, or copied \
                    incompletely — it's shown only once, so it's easy to lose the last few \
                    characters.
                    """
            )

        case .unreachable(let host, _):
            return .failed(
                message: """
                    Can't reach \(host). Check the address, and that you're on the same network \
                    as the server if it's not published to the internet.
                    """
            )

        case .malformedResponse:
            return .failed(
                message: """
                    \(host) answered, but not with a JMAP session. Check the address points at \
                    plMail itself and not at a router or a landing page.
                    """
            )

        case .unexpectedStatus(let code):
            return .failed(message: "\(host) answered with HTTP \(code).")

        default:
            return .failed(message: "\(host) couldn't be reached: \(error).")
        }
    }

    private static func describe(addressError: any Error) -> String {
        switch addressError {
        case ServerAddress.ParseError.empty:
            String(localized: "Enter your server's address.", bundle: .module)
        case ServerAddress.ParseError.unsupportedScheme(let scheme):
            "\(scheme):// isn't something this app can talk to. Use https, or http on a local network."
        case ServerAddress.ParseError.missingHost:
            String(localized: "That address is missing a hostname.", bundle: .module)
        case ServerAddress.ParseError.credentialsInAddress:
            String(
                localized: """
                    Leave the username and password out of the address — the app password goes in \
                    the field below.
                    """,
                bundle: .module)
        default:
            String(localized: "That address couldn't be read.", bundle: .module)
        }
    }
}
