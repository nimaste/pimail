import Foundation

/// How this client proves who it is.
///
/// Today there is one case. A JWT case is expected: the server's firewall
/// already accepts JWTs and generates a keypair on first start, but nothing
/// issues one yet — so a first-party app still has to ask the user to paste a
/// 71-character secret copied out of a web UI on another device. Because
/// ``authorizationHeader`` is computed, adding that case is one case, not a
/// refactor.
public enum Credential: Hashable, Sendable {
    /// An app password, created in the server's Settings → App passwords and
    /// shown exactly once.
    ///
    /// User-scoped rather than account-scoped: one credential reaches every
    /// connected mail account.
    case appPassword(String)

    /// The `plmail_` prefix is load-bearing on the server: a Bearer token that
    /// starts with it goes to the app-password authenticator, and anything
    /// else falls through to the JWT one. So a mistyped secret fails as a JWT
    /// with a confusing message rather than as a bad password.
    public static let appPasswordPrefix = "plmail_"

    public var authorizationHeader: String {
        switch self {
        case .appPassword(let secret):
            // Bearer rather than Basic. Both work, but Basic additionally
            // verifies the username against the token's owner, which is one
            // more thing to get wrong for no gain.
            "Bearer \(secret)"
        }
    }

    /// Whether the secret is even the right shape, checked before a network
    /// round trip so onboarding can say "that doesn't look like an app
    /// password" instead of "unauthorised".
    public var isWellFormed: Bool {
        switch self {
        case .appPassword(let secret):
            secret.hasPrefix(Self.appPasswordPrefix)
                && secret.dropFirst(Self.appPasswordPrefix.count).count == 64
                && secret.dropFirst(Self.appPasswordPrefix.count).allSatisfy(\.isHexDigit)
        }
    }

    /// The stored form, for a credential store to persist.
    public var secret: String {
        switch self {
        case .appPassword(let secret): secret
        }
    }
}
