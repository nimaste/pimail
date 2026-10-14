/// Namespace tag for ``Identifier``. Each conforming type names one id space.
public protocol IdentifierNamespace: Sendable {}

/// An opaque JMAP id, tagged with the space it belongs to.
///
/// JMAP ids are opaque strings and the spec forbids parsing them, so there is
/// nothing to model beyond the string. The reason they are not *just* strings
/// is that plMail has two id spaces which are both small integers and which
/// look interchangeable at a glance:
///
/// - a **Mailbox** id is a per-account `LabelBinding` id — what `inMailbox`,
///   `Email.mailboxIds` and `Email/set` all consume;
/// - a **Label** id is user-scoped and spans accounts, and appears only as
///   `Mailbox.labelId`, which exists so a client can group one label across
///   several accounts into a single sidebar row.
///
/// Passing one where the other belongs does not fail — the ids are
/// autoincrement ints from different tables, so a wrong id usually names some
/// unrelated mailbox and the app renders a plausible wrong answer. That is the
/// exact bug this type exists to make unrepresentable: ``LabelID`` and
/// ``MailboxID`` are different types and do not convert.
public struct Identifier<Namespace: IdentifierNamespace>: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

extension Identifier: Codable {
    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension Identifier: CustomStringConvertible {
    public var description: String { rawValue }
}

/// Without this, `Codable` treats a dictionary keyed by an id as an array of
/// alternating keys and values rather than as a JSON object — and the Session's
/// `accounts` map would decode to nothing recognisable.
extension Identifier: CodingKeyRepresentable {
    public var codingKey: any CodingKey { JMAPCodingKey(rawValue) }

    public init?(codingKey: some CodingKey) {
        self.init(rawValue: codingKey.stringValue)
    }
}

extension Identifier: Comparable {
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

// MARK: - The id spaces

public enum AccountNamespace: IdentifierNamespace {}
public enum EmailNamespace: IdentifierNamespace {}
public enum ThreadNamespace: IdentifierNamespace {}
public enum MailboxNamespace: IdentifierNamespace {}
public enum LabelNamespace: IdentifierNamespace {}
public enum IdentityNamespace: IdentifierNamespace {}
public enum BlobNamespace: IdentifierNamespace {}
public enum SubmissionNamespace: IdentifierNamespace {}

public typealias AccountID = Identifier<AccountNamespace>
public typealias EmailID = Identifier<EmailNamespace>
public typealias ThreadID = Identifier<ThreadNamespace>
public typealias MailboxID = Identifier<MailboxNamespace>
public typealias IdentityID = Identifier<IdentityNamespace>
public typealias SubmissionID = Identifier<SubmissionNamespace>

/// A user-scoped plMail label id, carried on ``Mailbox/labelID``.
///
/// Read-only, and deliberately not interchangeable with ``MailboxID``: no JMAP
/// argument accepts one. See ``Identifier``.
public typealias LabelID = Identifier<LabelNamespace>

/// An opaque blob handle.
///
/// Namespaced server-side — `m-` for a message's RFC822 source, `p-` for an
/// attachment part, `u-` for a staged upload — because the underlying tables
/// have independent autoincrement ids. **Never parse it.**
public typealias BlobID = Identifier<BlobNamespace>

/// A state token, as returned by every `/get` and `/changes` method.
///
/// Compared for equality and passed back as `sinceState`, never ordered or
/// interpreted. `"0"` is always answerable: plMail's change log uses one
/// sequence shared across every (account, type), so a type's first row can sit
/// at any number and a freshly-connected client must not be told to resync.
public struct StateToken: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    /// The token every client starts from.
    public static let initial = StateToken(rawValue: "0")

    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
}
