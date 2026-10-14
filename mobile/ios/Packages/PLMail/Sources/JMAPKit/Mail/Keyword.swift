/// An IMAP-style keyword on an Email.
///
/// plMail supports exactly four, and they are backed by two different things:
/// `$seen` and `$flagged` are the `seen_at` / `starred_at` columns the web UI
/// reads and writes, while `$draft` and `$answered` come from the IMAP flags
/// array, which only the plain-IMAP sync path populates.
///
/// **Anything else is rejected** with `unsupportedFilter` when filtered on, so
/// custom keywords cannot be used to carry client state — they will not round
/// trip. ``other(_:)`` exists only so that decoding an Email whose keywords
/// grew a fifth entry does not fail; encoding one is a programmer error and
/// traps.
public enum Keyword: Hashable, Sendable, RawRepresentable {
    case seen
    case flagged
    case draft
    case answered
    case other(String)

    public init(rawValue: String) {
        switch rawValue {
        case "$seen": self = .seen
        case "$flagged": self = .flagged
        case "$draft": self = .draft
        case "$answered": self = .answered
        default: self = .other(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .seen: "$seen"
        case .flagged: "$flagged"
        case .draft: "$draft"
        case .answered: "$answered"
        case .other(let value): value
        }
    }

    /// Whether the server will accept this keyword as a filter or a patch.
    public var isSupported: Bool {
        if case .other = self { return false }
        return true
    }
}

extension Keyword: Codable {
    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        precondition(
            isSupported,
            """
            Refusing to send the keyword "\(rawValue)". plMail supports only \
            $seen, $flagged, $draft and $answered; anything else comes back as \
            unsupportedFilter, and inventing one to carry client state cannot \
            round trip. Store the state locally instead — or ask for a server \
            change.
            """
        )

        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The keyword set on an Email. `{"$seen": true}` on the wire, `{}` when empty.
public typealias KeywordSet = JMAPIDSet<Keyword>
