import Foundation

/// The real transport.
public final class URLSessionTransport: JMAPTransport {
    private let session: URLSession
    private let trust: ServerTrust
    private let host: String

    /// - Parameters:
    ///   - host: Used only to name the machine in ``JMAPError/unreachable(host:code:)``.
    ///     Users self-host, so "can't reach nas.local" is worth more to them
    ///     than "the network connection was lost".
    ///   - trust: Certificate policy. See ``ServerTrust``.
    public init(host: String, trust: ServerTrust = ServerTrust()) {
        self.host = host
        self.trust = trust

        let configuration = URLSessionConfiguration.ephemeral
        // Every response carries its own state token and `/changes` is the
        // freshness mechanism, so an HTTP cache can only serve stale mail.
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        // A home uplink can be slow without being broken. The resource timeout
        // is what actually bounds a request; the per-hop one stays short so a
        // dead host fails quickly.
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.waitsForConnectivity = false

        session = URLSession(configuration: configuration, delegate: trust, delegateQueue: nil)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)

            guard let http = response as? HTTPURLResponse else {
                throw JMAPError.malformedResponse("Not an HTTP response.")
            }

            return (data, http)
        } catch let error as URLError {
            // A TLS failure with a fingerprint on hand is not a network
            // problem, it is a decision the user has to make — and it is the
            // single most likely first-run failure for a self-hosted server.
            if let fingerprint = trust.lastRejectedFingerprint, error.isTLSFailure {
                throw JMAPError.untrustedCertificate(host: host, fingerprint: fingerprint.hex)
            }

            throw JMAPError.unreachable(host: host, code: error.code)
        }
    }
}

extension URLError {
    var isTLSFailure: Bool {
        switch code {
        case .serverCertificateUntrusted, .serverCertificateHasBadDate,
            .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
            .clientCertificateRejected, .clientCertificateRequired,
            .secureConnectionFailed, .cancelled:
            // `.cancelled` is here because refusing a trust challenge surfaces
            // as a cancellation rather than as a certificate error — which
            // would otherwise be reported to the user as "you cancelled".
            true
        default:
            false
        }
    }
}
