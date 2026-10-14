/// `Identity/get` — the account's sendable addresses, primary first.
///
/// Fetched in v1 even though nothing sends yet: it is one call, it tells the
/// UI which addresses are "me" so a thread's participant list can elide the
/// user, and it is already there when compose lands.
public struct IdentityGet: JMAPMethod {
    public static let name = "Identity/get"
    public static let capability = Capability.submission

    public struct Arguments: Encodable, Sendable {
        public var accountID: AccountID
        public var ids: [IdentityID]?

        private enum CodingKeys: String, CodingKey {
            case accountID = "accountId"
            case ids
        }
    }

    public typealias Result = GetResult<Identity>

    public var arguments: Arguments

    public init(accountID: AccountID, ids: [IdentityID]? = nil) {
        arguments = Arguments(accountID: accountID, ids: ids)
    }
}

/// `Core/echo` — the cheapest possible round trip.
///
/// Useful for a connectivity check that proves credentials work without
/// touching any mail: it is the one method that takes no `accountId`.
public struct CoreEcho: JMAPMethod {
    public static let name = "Core/echo"
    public static let capability = Capability.core

    public typealias Arguments = JSONValue
    public typealias Result = JSONValue

    public var arguments: JSONValue

    public init(_ arguments: JSONValue = .object([:])) {
        self.arguments = arguments
    }
}
