/// `Mailbox/get`.
///
/// Unlike `Email/get`, `ids` may be null — an account has few mailboxes, so
/// fetching all of them is the normal call.
public struct MailboxGet: JMAPMethod {
    public static let name = "Mailbox/get"
    public static let capability = Capability.mail

    public struct Arguments: Encodable, Sendable {
        public var accountID: AccountID
        public var ids: [MailboxID]?
        /// **Leave this nil.** An account has a handful of mailboxes, so there
        /// is nothing to save by narrowing the property set — and narrowing it
        /// is how the two plMail extensions get lost: `toJmapWithProperties`
        /// filters against the requested names, so a list written from RFC 8621
        /// alone omits `labelId` and `color` and the client silently falls back
        /// to hashed tints and per-account labels, with a well-formed response
        /// and nothing to debug.
        public var properties: [String]?

        private enum CodingKeys: String, CodingKey {
            case accountID = "accountId"
            case ids, properties
        }
    }

    public typealias Result = GetResult<Mailbox>

    public var arguments: Arguments

    public init(accountID: AccountID, ids: [MailboxID]? = nil, properties: [String]? = nil) {
        arguments = Arguments(accountID: accountID, ids: ids, properties: properties)
    }
}

/// `Mailbox/query`.
public struct MailboxQuery: JMAPMethod {
    public static let name = "Mailbox/query"
    public static let capability = Capability.mail

    public struct Arguments: Encodable, Sendable {
        public var accountID: AccountID
        public var sort: [MailboxComparator]?
        public var position: Int?
        public var limit: Int?
        /// `Mailbox/query` returns `total` only when this is set — unlike
        /// `Email/query`, which always does.
        public var calculateTotal: Bool?

        private enum CodingKeys: String, CodingKey {
            case accountID = "accountId"
            case sort, position, limit, calculateTotal
        }
    }

    public struct Result: Decodable, Sendable {
        public var accountID: AccountID
        public var queryState: StateToken
        public var canCalculateChanges: Bool
        public var position: Int
        public var ids: [MailboxID]
        public var total: Int?

        private enum CodingKeys: String, CodingKey {
            case accountID = "accountId"
            case queryState, canCalculateChanges, position, ids, total
        }
    }

    public var arguments: Arguments

    public init(
        accountID: AccountID,
        sort: [MailboxComparator]? = nil,
        position: Int? = nil,
        limit: Int? = nil,
        calculateTotal: Bool? = nil
    ) {
        arguments = Arguments(
            accountID: accountID,
            sort: sort,
            position: position,
            limit: limit,
            calculateTotal: calculateTotal
        )
    }
}

/// `Mailbox/changes`.
///
/// Note a mailbox whose **counts** moved does not necessarily show up here, so
/// unread badges go stale until something else changes. Refresh counts
/// opportunistically with ``MailboxGet`` on foreground rather than polling.
public struct MailboxChanges: JMAPMethod {
    public static let name = "Mailbox/changes"
    public static let capability = Capability.mail

    public typealias Arguments = EmailChanges.Arguments
    public typealias Result = ChangesResult<MailboxID>

    public var arguments: Arguments

    public init(accountID: AccountID, sinceState: StateToken, maxChanges: Int? = nil) {
        arguments = Arguments(
            accountID: accountID, sinceState: sinceState, maxChanges: maxChanges)
    }
}
