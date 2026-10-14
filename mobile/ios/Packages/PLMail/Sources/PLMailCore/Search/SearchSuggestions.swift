import Foundation
import JMAPKit

/// A query split at the token being typed.
///
/// A completion replaces only that token, so `from:ada has:att` completes to
/// `from:ada has:attachment` rather than throwing away the sender. Everything
/// already typed is somebody's work.
public struct SearchDraft: Hashable, Sendable {
    /// Everything before the active token, trailing space included.
    public var prefix: String

    /// The token a completion replaces.
    public var activeToken: String

    public init(prefix: String, activeToken: String) {
        self.prefix = prefix
        self.activeToken = activeToken
    }

    /// The whole query text this completion would produce.
    public func completed(with completion: String) -> String {
        prefix + completion
    }

    /// Splits `raw` at the last space outside quotes.
    ///
    /// The quote rule is ``SearchQuery/tokenize``'s, deliberately: a space
    /// inside a quoted run does not end a token, so typing
    /// `subject:"quarterly rep` is still one token being edited and does not
    /// get completed as though `rep` were a new word.
    public static func of(_ raw: String) -> SearchDraft {
        var inQuote = false
        var breakpoint: String.Index?

        for index in raw.indices {
            let character = raw[index]

            if character == "\"" { inQuote.toggle() }

            if character == " ", inQuote == false { breakpoint = raw.index(after: index) }
        }

        guard let breakpoint else { return SearchDraft(prefix: "", activeToken: raw) }

        return SearchDraft(
            prefix: String(raw[..<breakpoint]), activeToken: String(raw[breakpoint...]))
    }
}

/// Something offered under the search field before a query is run.
///
/// Carries its own finished `completion` — the entire new query text — so the
/// view does no string surgery and the splicing rules are tested in one place.
public struct SearchSuggestion: Hashable, Sendable, Identifiable {
    public enum Kind: String, Hashable, Sendable {
        case recent
        case sender
        case searchOperator
    }

    public var kind: Kind

    /// The primary line: the query, the person, or the operator.
    public var title: String

    /// The second line, where there is one to give.
    public var detail: String?

    /// The whole search field contents this suggestion produces.
    public var completion: String

    /// Whether picking this should run the search or leave the caret typing.
    ///
    /// An operator taking a value is only half an intent — completing to
    /// `from:` and immediately searching for nothing would be worse than not
    /// offering it.
    public var isComplete: Bool

    public var id: String { "\(kind.rawValue)\u{1}\(title)\u{1}\(completion)" }

    public init(
        kind: Kind, title: String, detail: String? = nil, completion: String,
        isComplete: Bool = true
    ) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.completion = completion
        self.isComplete = isComplete
    }
}

/// What to offer while somebody is typing a search.
///
/// Pure, and therefore the part worth testing: the sources it draws on — what
/// has been searched before, who is in the synced mail — are supplied by the
/// caller rather than read here.
public enum SearchSuggestions {
    /// Per-group caps, so no one source can crowd the others out.
    ///
    /// Without these a person with a long history sees ten past searches and
    /// never learns an operator exists, which is the one thing this list is
    /// for. The caps are applied before the overall limit.
    private static let recentLimit = 3
    private static let operatorLimit = 4
    private static let senderLimit = 4

    /// - Parameters:
    ///   - raw: The search field's current contents.
    ///   - recents: Past searches, most recent first.
    ///   - correspondents: Addresses harvested from synced mail.
    ///   - limit: How many rows there is room for.
    /// - Returns: The rows to offer, most useful first.
    public static func suggest(
        for raw: String,
        recents: [String],
        correspondents: [EmailAddress],
        limit: Int = 8
    ) -> [SearchSuggestion] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Nothing typed: the field has just been tapped. Past searches are the
        // only thing that can be relevant, and the operator list would be a
        // wall of syntax as a greeting.
        guard trimmed.isEmpty == false else {
            return recents.prefix(limit).map(recent)
        }

        let draft = SearchDraft.of(raw)
        let token = draft.activeToken.lowercased()

        var suggestions = matchingRecents(trimmed, in: recents)

        suggestions += operators(for: token, draft: draft)
        suggestions += senders(for: token, draft: draft, correspondents: correspondents)

        return Array(suggestions.prefix(limit))
    }

    private static func recent(_ query: String) -> SearchSuggestion {
        SearchSuggestion(kind: .recent, title: query, completion: query)
    }

    /// Past searches containing what has been typed.
    ///
    /// One matching exactly is dropped: offering someone the string already in
    /// the field is a row that does nothing.
    private static func matchingRecents(
        _ trimmed: String, in recents: [String]
    ) -> [SearchSuggestion] {
        recents
            .filter {
                $0.localizedCaseInsensitiveContains(trimmed)
                    && $0.caseInsensitiveCompare(trimmed) != .orderedSame
            }
            .prefix(recentLimit)
            .map(recent)
    }

    /// Operators matching the token being typed.
    ///
    /// Two rules do all the work here, and it is worth saying why no third one
    /// is needed. Once a value is being typed — `from:ad`, `after:2024` — no
    /// operator can match: ``SearchOperator/matches(_:)`` asks whether the
    /// operator *starts with* what was typed, and a token carrying a value is
    /// always longer than the `from:` it began as. The only colon-bearing
    /// fragments that still match are the ones whose value belongs to the
    /// operator itself, `is:u` finding `is:unread`, which is exactly the case
    /// that should keep completing.
    ///
    /// That leaves the exact match — `from:` offering `from:` — which the
    /// filter below drops as a row that completes to what is already there. An
    /// explicit "suppress operators after a colon" guard was tried and removed:
    /// it could not change any outcome these two rules do not already give.
    private static func operators(for token: String, draft: SearchDraft) -> [SearchSuggestion] {
        SearchOperator.all
            .filter { $0.matches(token) && $0.token.lowercased() != token }
            .prefix(operatorLimit)
            .map {
                SearchSuggestion(
                    kind: .searchOperator,
                    title: $0.token,
                    detail: $0.explanation,
                    completion: draft.completed(with: $0.token),
                    // A value-taking operator leaves the caret where the value
                    // goes rather than searching for a half-written filter.
                    isComplete: $0.takesValue == false)
            }
    }

    /// People from synced mail, offered as a `from:` or `to:` filter.
    ///
    /// Completing a bare fragment to `from:` rather than to the address alone
    /// is the teaching move: typing "ada" and being handed `from:ada@example.com`
    /// shows what the operator is for at the moment it would have helped.
    /// Someone who wanted "ada" as free text has already typed it and can
    /// simply search.
    private static func senders(
        for token: String, draft: SearchDraft, correspondents: [EmailAddress]
    ) -> [SearchSuggestion] {
        let operatorName: String
        let fragment: String

        if let colon = token.firstIndex(of: ":") {
            let name = String(token[..<colon])

            // Only the operators that name a person. `subject:re` wants no
            // address book, and neither does `label:re`.
            guard ["from", "to", "cc"].contains(name) else { return [] }

            operatorName = name
            fragment = String(token[token.index(after: colon)...])
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        } else {
            operatorName = "from"
            fragment = token
        }

        // The compose field's ranking, reused rather than reimplemented: prefix
        // before substring, per word so a surname counts, and a two-character
        // floor below which every address matches and none of them help.
        let matches = RecipientSuggestions.merge(
            correspondents: correspondents, contacts: [], matching: fragment, limit: senderLimit)

        return matches.map { address in
            SearchSuggestion(
                kind: .sender,
                title: address.name?.isEmpty == false
                    ? (address.name ?? address.email)
                    : address.email,
                detail: address.email,
                completion: draft.completed(with: "\(operatorName):\(quoted(address.email))"))
        }
    }

    /// Addresses do not contain spaces in practice, but a display name pasted
    /// into the field could, and an unquoted space would split the token in
    /// two — the parser would read the second half as free text.
    private static func quoted(_ value: String) -> String {
        value.contains(" ") ? "\"\(value)\"" : value
    }
}
