import Foundation
import JMAPKit

/// A search string, parsed.
///
/// Mirrors `App\Domain\DTO\ParsedSearchQuery` field for field, because the two
/// clients have to agree about what a query means. Someone who searches
/// `from:acme is:unread` in the browser and then on their phone is entitled to
/// the same results.
public struct ParsedSearchQuery: Hashable, Sendable {
    public var from: String?
    public var to: String?
    /// The `cc:` operator, matched against `m.cc_addresses` server-side.
    ///
    /// Absent here until Wave 2C, which meant `cc:alice` was searched as the
    /// literal text `cc:alice` — a token no tsvector contains, so a perfectly
    /// valid query answered with nothing at all.
    ///
    /// `bcc:` is deliberately *not* here. `EmailFilterCompiler` understands the
    /// condition, but `SearchQueryParser` has no such operator, so offering it
    /// would build a query that works on the phone and fails in the browser —
    /// the one divergence this whole type exists to prevent.
    public var cc: String?
    public var subject: String?
    /// A user label, by its **leaf** name.
    ///
    /// The server compiles this to `LOWER(lbl.name) = :labelName AND lbl.role
    /// IS NULL`, and every part of that matters: exact rather than prefix, case
    /// insensitive, and role mailboxes excluded, so `label:inbox` finds nothing
    /// and `in:inbox` is the operator for that. It is not hierarchy-aware
    /// either — `label:work/invoices` matches nothing, because a leaf name
    /// cannot contain a slash. Resolving paths "helpfully" would make the
    /// phone answer a query the browser does not.
    public var label: String?
    public var hasAttachment: Bool?
    public var isUnread: Bool?
    public var isRead: Bool?
    public var isStarred: Bool?
    /// The **server's** role name, resolved through ``SearchQuery/roleAliases``
    /// — never the word the user typed.
    ///
    /// Holding the raw word let `in:spam` fail while `in:junk` worked, because
    /// iOS spells the role `junk` and the server spells it `spam`. Holding the
    /// server's spelling keeps this field readable against
    /// `ParsedSearchQuery::$mailboxRole`, and leaves exactly one place —
    /// ``SearchQueryCompiler`` — that has to know the two vocabularies differ.
    public var mailboxRole: String?
    public var after: Date?
    public var before: Date?

    /// Everything that was not an operator, joined with spaces.
    ///
    /// Quote characters survive tokenising deliberately: this string is handed
    /// to Postgres's `websearch_to_tsquery`, where a quoted run means a phrase
    /// search. Stripping them would quietly turn a phrase into a bag of words.
    public var freeText: String = ""

    public init() {}

    /// Whether anything was actually asked for.
    public var isEmpty: Bool {
        self == ParsedSearchQuery()
    }

    /// Whether the query narrowed by date.
    ///
    /// Worth knowing for the empty state: mail older than an account's sync
    /// window is not in the database at all, so "no results" for a dated query
    /// usually means the window, not the mail.
    public var hasDateBound: Bool {
        after != nil || before != nil
    }

    /// Whether the query asks for mail that is both read and unread.
    ///
    /// Both flags are honoured independently, exactly as the server honours
    /// them, so this returns nothing — which is correct and completely
    /// unexplained unless something says so. See `SearchNoticesView`.
    public var isContradictory: Bool {
        isRead == true && isUnread == true
    }
}

/// Parses a Gmail-style search string.
///
/// A deliberate reimplementation of `SearchQueryParser.php`, including the
/// parts that look like bugs, because matching the server is the whole point.
/// The behaviours worth naming, since each one is a decision:
///
/// - **Quote characters are kept inside tokens.** They are only stripped from
///   an operator's *value*.
/// - **A token splits on its first colon**, so `subject:a:b` searches for
///   `a:b`.
/// - **An unknown operator falls through as free text, colon and all** —
///   `weird:thing` searches for the literal `weird:thing` rather than erroring.
/// - **An unrecognised *value* for a known operator also falls through as free
///   text.** `is:bogus` used to be dropped here, which left the query narrowing
///   nothing and searching for nothing — that is, answering with the entire
///   mailbox, looking exactly as though the search had been ignored. The server
///   changed its mind about this and said why: as free text the query finds
///   little or nothing, "which is at least the truth". This client had the old
///   rule written down as deliberate policy; it is not, any more.
/// - **An *empty* value on a known operator is neither a filter nor free
///   text.** `from:` mid-typing must not search for the word "from", and an
///   empty substring match would select the whole mailbox. `Re:` is an unknown
///   operator, so it stays searchable as the word somebody typed.
/// - **`is:unread` and `is:read` are independent flags.** Setting both is
///   contradictory and yields nothing, on both clients.
public enum SearchQuery {
    /// The operator names the parser knows, for telling a half-typed operator
    /// from a word that happens to end in a colon.
    ///
    /// Mirrors `SearchQueryParser::OPERATORS`. Membership here is what decides
    /// whether an empty value is swallowed or searched for, so a name missing
    /// from this list makes `Re:` of a real operator.
    static let operatorNames: Set<String> = [
        "from", "to", "cc", "subject", "label", "has", "is", "in", "after", "before",
    ]

    /// `in:` as typed, mapped to the role plMail stores.
    ///
    /// Mirrors `SearchQueryParser::ROLES` exactly — twelve aliases onto eight
    /// roles. Passing the typed word straight through instead used to break in
    /// both directions at once: `in:draft`, `in:deleted`, `in:bin`, `in:spam`
    /// and `in:archived` all work in the browser and returned nothing here,
    /// while `in:flagged`, `in:important` and `in:all` narrowed here and are
    /// free text in the browser.
    static let roleAliases: [String: String] = [
        "inbox": "inbox",
        "sent": "sent",
        "drafts": "drafts",
        "draft": "drafts",
        "trash": "trash",
        "deleted": "trash",
        "bin": "trash",
        "junk": "spam",
        "spam": "spam",
        "archive": "archive",
        "archived": "archive",
        "snoozed": "snoozed",
    ]

    public static func parse(_ raw: String) -> ParsedSearchQuery {
        var query = ParsedSearchQuery()
        var remainder: [String] = []

        for token in tokenize(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            guard token.contains(":") else {
                remainder.append(token)
                continue
            }

            // First colon only, so a value may itself contain colons.
            let parts = token.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let name = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(parts.count > 1 ? parts[1] : "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

            guard value.isEmpty == false else {
                // A known operator on its way to being typed: not a filter, and
                // not a word either. An unknown one is `Re:`, and swallowing it
                // left the person searching for nothing at all.
                guard operatorNames.contains(name) else {
                    remainder.append(token)
                    continue
                }

                applyEmpty(name, to: &query)
                continue
            }

            let applied: Bool

            switch name {
            case "from": applied = assign(value, to: &query.from)
            case "to": applied = assign(value, to: &query.to)
            case "cc": applied = assign(value, to: &query.cc)
            case "subject": applied = assign(value, to: &query.subject)
            case "label": applied = assign(value, to: &query.label)
            case "has": applied = applyHas(value, to: &query)
            case "is": applied = applyIs(value, to: &query)
            case "in": applied = applyIn(value, to: &query)
            case "after":
                query.after = parseDate(value)
                applied = query.after != nil
            case "before":
                query.before = parseDate(value)
                applied = query.before != nil
            default:
                applied = false
            }

            // The whole original token, colon included.
            if applied == false { remainder.append(token) }
        }

        query.freeText = remainder.joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)

        return query
    }

    /// Splits on spaces, keeping quoted runs together.
    ///
    /// The quote characters stay in the token — see ``ParsedSearchQuery/freeText``.
    /// An unterminated quote swallows the rest of the string, which is what the
    /// server does and is the more forgiving reading of a half-typed query.
    static func tokenize(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuote = false

        for character in input {
            if character == "\"" {
                inQuote.toggle()
                current.append(character)
                continue
            }

            if character == " ", inQuote == false {
                if current.isEmpty == false {
                    tokens.append(current)
                    current = ""
                }
                continue
            }

            current.append(character)
        }

        if current.isEmpty == false {
            tokens.append(current)
        }

        return tokens
    }

    /// Records a half-typed operator without letting it narrow or search.
    ///
    /// The substring operators keep the empty string rather than staying nil,
    /// which is this client's route to the server's outcome: the compiler skips
    /// empty values, and an empty `ILIKE '%%'` matches everything, so both ends
    /// agree that `from:` filters nothing.
    private static func applyEmpty(_ name: String, to query: inout ParsedSearchQuery) {
        switch name {
        case "from": query.from = ""
        case "to": query.to = ""
        case "cc": query.cc = ""
        case "subject": query.subject = ""
        case "label": query.label = ""
        default: break
        }
    }

    /// Stores a substring operator's value and reports whether the server would
    /// have called it applied.
    ///
    /// The value is stored either way, and then coerced — because the server
    /// writes `(bool) ($filters->from = $value)`, and PHP coerces the string
    /// `"0"` to false. So `from:0` really does set the filter *and* push
    /// `from:0` into free text over there. Reproduced rather than tidied up:
    /// the whole contract of this file is that a query means the same thing in
    /// both clients, quirks included.
    private static func assign(_ value: String, to field: inout String?) -> Bool {
        field = value

        return value != "0"
    }

    private static func applyHas(_ value: String, to query: inout ParsedSearchQuery) -> Bool {
        switch value.lowercased() {
        case "attachment", "attachments":
            query.hasAttachment = true
            return true
        default:
            return false
        }
    }

    private static func applyIs(_ value: String, to query: inout ParsedSearchQuery) -> Bool {
        switch value.lowercased() {
        case "unread":
            query.isUnread = true
            return true
        case "read":
            query.isRead = true
            return true
        case "starred":
            query.isStarred = true
            return true
        default:
            return false
        }
    }

    /// Resolves `in:` through the server's alias table, or leaves it for free
    /// text.
    private static func applyIn(_ value: String, to query: inout ParsedSearchQuery) -> Bool {
        guard let role = roleAliases[value.lowercased()] else { return false }

        query.mailboxRole = role

        return true
    }

    /// Parses a date the way a person would write one.
    ///
    /// The server hands the value to PHP's `DateTimeImmutable`, which accepts
    /// an enormous range. Most of it is unreachable through the search box in
    /// either client — the tokeniser splits on spaces, so `after:-7 days` was
    /// never one token — so this covers the formats the docs promise, the
    /// relative words people reach for, and `@`-epoch, which is the one exotic
    /// spelling that survives tokenising.
    ///
    /// Anything else returns nil and the whole token becomes free text, which
    /// is the server's rule since Wave 2C: `after:whenever` searches for the
    /// words rather than quietly widening the query to everything.
    ///
    /// Dates are anchored at **local** midnight, because a typed date means
    /// that day where the person is. The server parses in *its own* timezone,
    /// which can differ by an offset — but that is ambiguous there too: the
    /// same query from the same person means different things depending on
    /// where their server thinks it is.
    static func parseDate(_ value: String, now: Date = .now) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)

        guard trimmed.isEmpty == false else { return nil }

        let calendar = Calendar.current
        let midnight = calendar.startOfDay(for: now)

        switch trimmed.lowercased() {
        case "now": return now
        case "today": return midnight
        case "yesterday": return calendar.date(byAdding: .day, value: -1, to: midnight)
        case "tomorrow": return calendar.date(byAdding: .day, value: 1, to: midnight)
        default: break
        }

        // PHP's `@1700000000` — seconds since the epoch, and the only
        // `DateTimeImmutable` spelling with no spaces in it that this would
        // otherwise refuse.
        if trimmed.hasPrefix("@"), let seconds = TimeInterval(trimmed.dropFirst()) {
            return Date(timeIntervalSince1970: seconds)
        }

        // Single-digit months and days included: `2024-1-5` is a date PHP reads
        // and a person types, and refusing it would send the token to free text
        // where it finds nothing.
        let formats = [
            "yyyy-MM-dd", "yyyy-M-d", "yyyy/MM/dd", "yyyy/M/d",
            "dd.MM.yyyy", "d.M.yyyy", "yyyy-MM-dd HH:mm:ss",
        ]

        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = format

            if let date = formatter.date(from: trimmed) { return date }
        }

        return try? Date(trimmed, strategy: .iso8601)
    }
}
