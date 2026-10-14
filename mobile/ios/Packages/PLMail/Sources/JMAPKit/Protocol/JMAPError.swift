import Foundation

/// Everything that can go wrong between asking the server something and having
/// a decoded answer.
///
/// The cases are split by **what the caller should do**, not by where the
/// failure came from, because that is the only distinction the UI and the sync
/// engine actually act on.
public enum JMAPError: Error, Hashable, Sendable {
    /// 401 with `application/problem+json`.
    ///
    /// Never retry and never back off — an app password that was revoked stays
    /// revoked. This goes straight to a re-auth flow.
    case notAuthenticated(detail: String?)

    /// A request-level failure: `notJSON`, `notRequest`, `unknownCapability`.
    /// Always a client bug — the request never reached a method.
    case requestFailed(type: String, detail: String?)

    /// A single call failed, inline in an otherwise-successful response.
    case methodFailed(MethodErrorType, description: String?, callID: CallID)

    /// An unexpected HTTP status with no problem document to explain it.
    case unexpectedStatus(code: Int)

    /// The server could not be reached. Carries the host because plMail users
    /// self-host, and "can't reach nas.local" is genuinely more useful to them
    /// than "the network is unavailable".
    case unreachable(host: String, code: URLError.Code)

    /// TLS evaluation failed and the certificate is not pinned. Carries the
    /// SPKI fingerprint so onboarding can show it and offer to trust it.
    case untrustedCertificate(host: String, fingerprint: String)

    /// The response was not the shape this client expects.
    case malformedResponse(String)

    /// A call was issued for a result that was never requested — a builder bug.
    case noSuchCall(CallID)
}

extension JMAPError {
    /// Whether retrying could plausibly succeed.
    ///
    /// Auth failures and method errors are excluded on purpose: both are
    /// deterministic, and retrying an auth failure against someone's home
    /// server is how a client turns one problem into a hammering loop.
    public var isRetryable: Bool {
        switch self {
        case .unreachable, .unexpectedStatus:
            true
        case .notAuthenticated, .requestFailed, .methodFailed, .untrustedCertificate,
            .malformedResponse, .noSuchCall:
            false
        }
    }

    /// True when the error means "your cursor is too old, start over" rather
    /// than "something is broken". The sync engine treats this as an
    /// instruction, not a failure.
    public var requiresResync: Bool {
        guard case .methodFailed(let type, _, _) = self else { return false }
        return type == .cannotCalculateChanges
    }

    /// True when the error can only be caused by this client building a bad
    /// request. These are worth an assertion in debug and a log line with the
    /// call id in release — but never a raw error string in front of a user.
    public var isProgrammerError: Bool {
        switch self {
        case .requestFailed, .noSuchCall:
            true
        case .methodFailed(let type, _, _):
            switch type {
            case .invalidArguments, .unsupportedFilter, .unsupportedSort, .unknownMethod,
                .invalidResultReference, .unknownCapability:
                true
            default:
                false
            }
        default:
            false
        }
    }
}

/// A JMAP method-level error type (RFC 8620 §3.6.2), plus the mail-specific
/// ones plMail raises.
public enum MethodErrorType: Hashable, Sendable, RawRepresentable, Decodable {
    case serverUnavailable
    case serverFail
    case serverPartialFail
    case unknownMethod
    case invalidArguments
    case invalidResultReference
    case forbidden
    case accountNotFound
    case accountNotSupportedByMethod
    case accountReadOnly
    case unknownCapability
    case requestTooLarge
    case unsupportedFilter
    case unsupportedSort
    /// The `sinceState` is too old to answer. Not a failure — drop the cursor
    /// for that account and re-page.
    case cannotCalculateChanges
    /// The requested calendar window lies outside what the server has
    /// materialised. **The whole query is refused, not answered short**, so a
    /// client must clamp its window before asking rather than trimming the
    /// result afterwards.
    case cannotCalculateOccurrences
    case stateMismatch
    case tooLarge
    case rateLimit
    case notFound
    case invalidProperties
    case alreadyExists
    case singleton
    case other(String)

    public init(rawValue: String) {
        switch rawValue {
        case "serverUnavailable": self = .serverUnavailable
        case "serverFail": self = .serverFail
        case "serverPartialFail": self = .serverPartialFail
        case "unknownMethod": self = .unknownMethod
        case "invalidArguments": self = .invalidArguments
        case "invalidResultReference": self = .invalidResultReference
        case "forbidden": self = .forbidden
        case "accountNotFound": self = .accountNotFound
        case "accountNotSupportedByMethod": self = .accountNotSupportedByMethod
        case "accountReadOnly": self = .accountReadOnly
        case "unknownCapability": self = .unknownCapability
        case "requestTooLarge": self = .requestTooLarge
        case "unsupportedFilter": self = .unsupportedFilter
        case "unsupportedSort": self = .unsupportedSort
        case "cannotCalculateChanges": self = .cannotCalculateChanges
        case "cannotCalculateOccurrences": self = .cannotCalculateOccurrences
        case "stateMismatch": self = .stateMismatch
        case "tooLarge": self = .tooLarge
        case "rateLimit": self = .rateLimit
        case "notFound": self = .notFound
        case "invalidProperties": self = .invalidProperties
        case "alreadyExists": self = .alreadyExists
        case "singleton": self = .singleton
        default: self = .other(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .serverUnavailable: "serverUnavailable"
        case .serverFail: "serverFail"
        case .serverPartialFail: "serverPartialFail"
        case .unknownMethod: "unknownMethod"
        case .invalidArguments: "invalidArguments"
        case .invalidResultReference: "invalidResultReference"
        case .forbidden: "forbidden"
        case .accountNotFound: "accountNotFound"
        case .accountNotSupportedByMethod: "accountNotSupportedByMethod"
        case .accountReadOnly: "accountReadOnly"
        case .unknownCapability: "unknownCapability"
        case .requestTooLarge: "requestTooLarge"
        case .unsupportedFilter: "unsupportedFilter"
        case .unsupportedSort: "unsupportedSort"
        case .cannotCalculateChanges: "cannotCalculateChanges"
        case .cannotCalculateOccurrences: "cannotCalculateOccurrences"
        case .stateMismatch: "stateMismatch"
        case .tooLarge: "tooLarge"
        case .rateLimit: "rateLimit"
        case .notFound: "notFound"
        case .invalidProperties: "invalidProperties"
        case .alreadyExists: "alreadyExists"
        case .singleton: "singleton"
        case .other(let value): value
        }
    }

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }
}

/// The body of an `["error", …]` entry, and of a request-level
/// `application/problem+json`.
struct ProblemDocument: Decodable {
    var type: String?
    var status: Int?
    var detail: String?
    var description: String?
}
