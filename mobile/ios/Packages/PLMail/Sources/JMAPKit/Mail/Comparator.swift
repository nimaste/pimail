/// A sort comparator for `Email/query`.
///
/// The properties are restricted to what the server advertises in
/// `emailQuerySortOptions`; anything else raises `unsupportedSort`.
public struct EmailComparator: Hashable, Sendable, Encodable {
    public enum Property: String, Hashable, Sendable, Encodable {
        case receivedAt
        case from
        case to
        case subject
        case size
    }

    public var property: Property
    public var isAscending: Bool

    public init(_ property: Property, isAscending: Bool = false) {
        self.property = property
        self.isAscending = isAscending
    }

    /// Newest first — the ordering every mail list uses, and the one the feed
    /// pages against.
    public static let newestFirst = EmailComparator(.receivedAt, isAscending: false)
}

/// A sort comparator for `Mailbox/query`.
public struct MailboxComparator: Hashable, Sendable, Encodable {
    public enum Property: String, Hashable, Sendable, Encodable {
        case sortOrder
        case name
    }

    public var property: Property
    public var isAscending: Bool

    public init(_ property: Property, isAscending: Bool = true) {
        self.property = property
        self.isAscending = isAscending
    }
}
