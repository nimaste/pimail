/// `Thread/get`.
public struct ThreadGet: JMAPMethod {
    public static let name = "Thread/get"
    public static let capability = Capability.mail

    public struct Arguments: Encodable, Sendable {
        public var accountID: AccountID
        public var ids: Argument<[ThreadID]>

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: JMAPCodingKey.self)
            try container.encode(accountID, forKey: JMAPCodingKey("accountId"))
            try ids.encode(into: &container, as: "ids")
        }
    }

    public typealias Result = GetResult<MailThread>

    public var arguments: Arguments

    public init(accountID: AccountID, ids: Argument<[ThreadID]>) {
        arguments = Arguments(accountID: accountID, ids: ids)
    }
}

/// `Thread/changes`.
public struct ThreadChanges: JMAPMethod {
    public static let name = "Thread/changes"
    public static let capability = Capability.mail

    public typealias Arguments = EmailChanges.Arguments
    public typealias Result = ChangesResult<ThreadID>

    public var arguments: Arguments

    public init(accountID: AccountID, sinceState: StateToken, maxChanges: Int? = nil) {
        arguments = Arguments(
            accountID: accountID, sinceState: sinceState, maxChanges: maxChanges)
    }
}
