/// A filter for `Email/query`.
///
/// There is a case here for every condition `EmailFilterCompiler` actually
/// compiles, and **no case for anything else**. That is the point: the server
/// raises `unsupportedFilter` on any condition it does not recognise rather
/// than dropping it silently — a quietly-ignored filter returns too many
/// emails and the client cannot tell — so the safest place to catch a bad
/// filter is where it cannot be written down.
///
/// Two deliberate omissions:
///
/// - `hasLabel` / `notLabel` exist in the compiler but take user-scoped Label
///   ids. They were added for mail rules, which have no reason to know about
///   the JMAP id space. Using them from a client would mean reasoning in two
///   id spaces at once, which is the confusion ``Identifier`` exists to
///   prevent.
/// - A condition object carrying several properties at once (implicit AND) has
///   no case, because ``and(_:)`` says the same thing and encodes to one
///   unambiguous shape.
public indirect enum EmailFilter: Hashable, Sendable {
    case and([EmailFilter])
    case or([EmailFilter])
    /// Compiled as `NOT (a OR b …)` — "none of", not "not all of".
    case not([EmailFilter])

    /// A Mailbox (binding) id.
    case inMailbox(MailboxID)
    /// Must be non-empty; the server rejects an empty array.
    case inMailboxOtherThan([MailboxID])

    /// Strict `<` against `received_at`.
    case before(UTCDate)
    /// Inclusive `>=` against `received_at`.
    case after(UTCDate)

    case minSize(Int)
    case maxSize(Int)

    case hasKeyword(Keyword)
    case notKeyword(Keyword)

    case hasAttachment(Bool)

    /// Real full-text search: a Postgres `tsvector` matched with
    /// `websearch_to_tsquery('english')`. Stemmed and ranked, not a substring
    /// scan — so quoted phrases work, and `transferring` finds `transfer`.
    case text(String)

    /// Substring, case-insensitive.
    case body(String)
    /// Substring, case-insensitive.
    case subject(String)
    /// Substring over both the address and the display name.
    case from(String)

    /// Substring over the serialised address array — matches name or address.
    case to(String)
    case cc(String)
    case bcc(String)

    /// Substring over attachment filenames. Inline parts have no filename and
    /// never match.
    case filename(String)

    /// Substring over the canonicalised `list-id` header.
    case listID(String)

    /// The conversation's inbox category — a plMail extension, not RFC 8621.
    ///
    /// Typed rather than a raw string because the server answers an unknown
    /// value with `invalidArguments` and the whole vocabulary in the message,
    /// which is a round trip spent learning something the client can know at
    /// compile time.
    case threadCategory(MessageCategory)
}

extension EmailFilter: Encodable {
    private enum OperatorKey: String, CodingKey {
        case `operator`
        case conditions
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .and(let conditions):
            try encodeOperator("AND", conditions, to: encoder)
        case .or(let conditions):
            try encodeOperator("OR", conditions, to: encoder)
        case .not(let conditions):
            try encodeOperator("NOT", conditions, to: encoder)

        case .inMailbox(let id):
            try encodeCondition("inMailbox", id, to: encoder)
        case .inMailboxOtherThan(let ids):
            precondition(ids.isEmpty == false, "inMailboxOtherThan must name at least one mailbox.")
            try encodeCondition("inMailboxOtherThan", ids, to: encoder)

        case .before(let date):
            try encodeCondition("before", date, to: encoder)
        case .after(let date):
            try encodeCondition("after", date, to: encoder)

        case .minSize(let bytes):
            try encodeCondition("minSize", bytes, to: encoder)
        case .maxSize(let bytes):
            try encodeCondition("maxSize", bytes, to: encoder)

        case .hasKeyword(let keyword):
            try encodeCondition("hasKeyword", keyword, to: encoder)
        case .notKeyword(let keyword):
            try encodeCondition("notKeyword", keyword, to: encoder)

        case .hasAttachment(let value):
            try encodeCondition("hasAttachment", value, to: encoder)

        case .text(let value):
            try encodeCondition("text", value, to: encoder)
        case .body(let value):
            try encodeCondition("body", value, to: encoder)
        case .subject(let value):
            try encodeCondition("subject", value, to: encoder)
        case .from(let value):
            try encodeCondition("from", value, to: encoder)
        case .to(let value):
            try encodeCondition("to", value, to: encoder)
        case .cc(let value):
            try encodeCondition("cc", value, to: encoder)
        case .bcc(let value):
            try encodeCondition("bcc", value, to: encoder)
        case .filename(let value):
            try encodeCondition("filename", value, to: encoder)
        case .listID(let value):
            try encodeCondition("listId", value, to: encoder)
        case .threadCategory(let category):
            try encodeCondition("threadCategory", category.rawValue, to: encoder)
        }
    }

    private func encodeOperator(
        _ name: String,
        _ conditions: [EmailFilter],
        to encoder: any Encoder
    ) throws {
        var container = encoder.container(keyedBy: OperatorKey.self)
        try container.encode(name, forKey: .operator)
        try container.encode(conditions, forKey: .conditions)
    }

    private func encodeCondition(
        _ property: String,
        _ value: some Encodable,
        to encoder: any Encoder
    ) throws {
        var container = encoder.container(keyedBy: JMAPCodingKey.self)
        try container.encode(value, forKey: JMAPCodingKey(property))
    }
}
