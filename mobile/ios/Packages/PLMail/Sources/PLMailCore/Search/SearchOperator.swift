import Foundation

/// An operator the search field understands, as something offerable.
///
/// The operators are the most valuable thing about this search field and the
/// least discoverable: nobody arrives at `has:attachment` by guessing. They
/// were previously named only in a paragraph under the empty state, which is
/// the one moment a person is *not* trying to narrow anything. Offering them
/// while typing puts the explanation where the intent is.
///
/// The list is deliberately the parser's own vocabulary and nothing more, and
/// the parser's vocabulary is the *server's*. Offering an operator the web UI
/// does not have — `bcc:`, which the JMAP filter compiler would happily answer,
/// or `category:`, which it would also answer — teaches a query that works on
/// the phone and finds nothing in the browser.
public struct SearchOperator: Hashable, Sendable, Identifiable {
    /// What gets inserted. Ones taking a value end in a colon and leave the
    /// caret ready to type it; ones that are complete in themselves do not.
    public var token: String

    /// One line, in plain words. Not syntax — someone who needed the syntax
    /// explained would not be reading a caption in a suggestion row.
    public var explanation: String

    public var id: String { token }

    /// Whether the operator still wants a value after it is inserted.
    public var takesValue: Bool { token.hasSuffix(":") }

    public init(token: String, explanation: String) {
        self.token = token
        self.explanation = explanation
    }

    /// Every operator, in the order they are offered.
    ///
    /// Ordered by how often they are the thing someone wants rather than
    /// alphabetically: sender first, because "mail from this person" is the
    /// commonest reason anyone searches mail at all.
    ///
    /// `is:read` is missing on purpose. The parser accepts it, and it stays
    /// accepted, but offering it alongside `is:unread` invites tapping both —
    /// which the server and this app agree returns nothing, being a
    /// contradiction neither client resolves. An operator whose discoverable
    /// use is a dead end is not worth a row.
    public static var all: [SearchOperator] {
        [
            SearchOperator(
                token: "from:",
                explanation: String(localized: "Mail from a person", bundle: .module)),
            SearchOperator(
                token: "to:",
                explanation: String(localized: "Mail sent to a person", bundle: .module)),
            SearchOperator(
                token: "cc:",
                explanation: String(localized: "Mail copied to a person", bundle: .module)),
            SearchOperator(
                token: "subject:",
                explanation: String(localized: "Words in the subject line", bundle: .module)),
            SearchOperator(
                token: "label:",
                explanation: String(
                    localized: "One label, by its exact name", bundle: .module)),
            SearchOperator(
                token: "has:attachment",
                explanation: String(localized: "Only mail with a file attached", bundle: .module)),
            SearchOperator(
                token: "is:unread",
                explanation: String(localized: "Only mail you haven't read", bundle: .module)),
            SearchOperator(
                token: "is:starred",
                explanation: String(localized: "Only mail you starred", bundle: .module)),
            SearchOperator(
                token: "in:",
                explanation: String(localized: "One mailbox, such as in:inbox", bundle: .module)),
            SearchOperator(
                token: "after:",
                explanation: String(
                    localized: "Mail since a date, like 2024-01-31", bundle: .module)
            ),
            SearchOperator(
                token: "before:",
                explanation: String(
                    localized: "Mail up to a date, like 2024-01-31", bundle: .module)
            ),
        ]
    }

    /// Whether this operator is worth offering for what has been typed so far.
    ///
    /// Matched on the whole token and, separately, on the part after the colon,
    /// so "unr" finds `is:unread` — people type the word they mean, not the
    /// namespace it happens to live under.
    func matches(_ fragment: String) -> Bool {
        guard fragment.isEmpty == false else { return true }

        let token = token.lowercased()

        if token.hasPrefix(fragment) { return true }

        guard let colon = token.firstIndex(of: ":") else { return false }

        return token[token.index(after: colon)...].hasPrefix(fragment)
    }
}
