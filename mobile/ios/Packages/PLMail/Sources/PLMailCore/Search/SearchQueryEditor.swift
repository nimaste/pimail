import Foundation

/// A quick narrowing offered once results are showing.
///
/// Deliberately a small set. These are the three narrowings people reach for
/// after seeing too many results, and each one is expressible as an operator
/// the parser already has — which is the point: a chip writes the operator into
/// the query rather than filtering behind its back.
public enum SearchFilterChip: String, CaseIterable, Sendable, Identifiable {
    case unread
    case hasAttachment

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .unread: String(localized: "Unread", bundle: .module)
        case .hasAttachment: String(localized: "Has attachment", bundle: .module)
        }
    }

    public var symbolName: String {
        switch self {
        case .unread: "envelope.badge"
        case .hasAttachment: "paperclip"
        }
    }

    /// The operator this chip writes.
    var token: String {
        switch self {
        case .unread: "is:unread"
        case .hasAttachment: "has:attachment"
        }
    }
}

/// How far back a date chip reaches.
///
/// Not ``TimePreset``, which resolves *future* times for snooze and send-later
/// and whose cases ("this weekend", "tomorrow evening") mean nothing looking
/// backwards. Sharing the type would mean one enum whose cases are valid in
/// opposite directions depending on the caller.
///
/// One-ended on purpose. A search narrowed to "since" is the question people
/// actually have — "where is that thing from last week" — and a second bound
/// needs two pickers to express something almost nobody wants. `before:` stays
/// available by typing, and is shown as a token when it is used.
public enum SearchDatePreset: String, CaseIterable, Sendable, Identifiable {
    case week
    case month
    case year

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .week: String(localized: "Past week", bundle: .module)
        case .month: String(localized: "Past month", bundle: .module)
        case .year: String(localized: "Past year", bundle: .module)
        }
    }

    /// Resolved against a calendar rather than by subtracting intervals, so
    /// "past month" means the same day last month and not thirty days.
    public func date(from now: Date = .now, calendar: Calendar = .current) -> Date? {
        let start = calendar.startOfDay(for: now)

        return switch self {
        case .week: calendar.date(byAdding: .day, value: -7, to: start)
        case .month: calendar.date(byAdding: .month, value: -1, to: start)
        case .year: calendar.date(byAdding: .year, value: -1, to: start)
        }
    }
}

/// Edits a raw search string, keeping it the single source of truth.
///
/// The chips could have been a separate set of flags ANDed onto the compiled
/// filter, which would have been less code. They are not, because then the
/// field would say `invoice` while the results were `invoice is:unread`, and
/// the one thing this search field does well is show people how their query was
/// read. A chip that writes into the text is a chip whose state cannot drift
/// from the search that ran, cannot be lost when the query is re-run, and can
/// be undone by editing the text like anything else.
///
/// Every edit goes through ``SearchQuery/tokenize``, so quoting and the
/// first-colon rule are the parser's own and cannot disagree with it.
public enum SearchQueryEditor {
    /// Whether a chip is on, read from the parsed query.
    ///
    /// Derived rather than stored: a chip lights up for an `is:unread` that was
    /// typed by hand, because as far as the query is concerned there is no
    /// difference, and a chip that ignored typed text would be lying.
    public static func isActive(_ chip: SearchFilterChip, in query: ParsedSearchQuery) -> Bool {
        switch chip {
        case .unread: query.isUnread == true
        case .hasAttachment: query.hasAttachment == true
        }
    }

    /// The query with `chip` turned on if it was off, and off if it was on.
    public static func toggling(_ chip: SearchFilterChip, in raw: String) -> String {
        let isOn = isActive(chip, in: SearchQuery.parse(raw))
        var edited = removing(chip, in: raw)

        guard isOn == false else { return edited }

        // Turning "unread" on while `is:read` is present would leave a
        // contradiction, which both this app and the server answer with no
        // results at all — so the chip would look broken. Dropping the
        // conflicting operator is an edit to visible text, not a hidden
        // override: it disappears from the field where the person can see it.
        if chip == .unread { edited = removingRead(in: edited) }

        return appending(chip.token, to: edited)
    }

    /// The query with `chip` removed, whatever spelling it was written in.
    public static func removing(_ chip: SearchFilterChip, in raw: String) -> String {
        switch chip {
        case .unread:
            removingTokens(in: raw) { name, value in
                name == "is" && value.lowercased() == "unread"
            }

        case .hasAttachment:
            removingTokens(in: raw) { name, value in
                // Both spellings the parser accepts, or the chip would fail to
                // clear a `has:attachments` it had itself lit up for.
                name == "has" && ["attachment", "attachments"].contains(value.lowercased())
            }
        }
    }

    /// The query with every `is:read` taken out.
    ///
    /// The escape from `is:read is:unread`, which both clients answer with
    /// nothing at all. Written as an edit to the visible text — the same way
    /// the unread chip resolves the same conflict — so the field, the tokens
    /// and the results still agree afterwards.
    public static func removingRead(in raw: String) -> String {
        removingTokens(in: raw) { name, value in
            name == "is" && value.lowercased() == "read"
        }
    }

    /// The query narrowed to mail on or after `date`, replacing any existing
    /// bound. Passing nil clears it.
    ///
    /// Written in `yyyy-MM-dd`, which is the documented format, is what the
    /// server's own parser reads, and is unambiguous in a way `05.01.2024`
    /// is not — this string is shown to the person as well as parsed.
    public static func settingAfter(_ date: Date?, in raw: String) -> String {
        let cleared = removingTokens(in: raw) { name, _ in name == "after" }

        guard let date else { return cleared }

        return appending("after:\(iso.string(from: date))", to: cleared)
    }

    /// The preset a query's `after:` corresponds to, if it is one of them.
    ///
    /// Compared by day rather than by instant: the token carries a date and the
    /// preset resolves to local midnight, so an exact match is the only sane
    /// test and a query typed as `after:2024-01-31` should light the chip if it
    /// happens to land on the same day.
    public static func activePreset(
        in query: ParsedSearchQuery, now: Date = .now, calendar: Calendar = .current
    ) -> SearchDatePreset? {
        guard let after = query.after else { return nil }

        return SearchDatePreset.allCases.first { preset in
            guard let date = preset.date(from: now, calendar: calendar) else { return false }

            return calendar.isDate(date, inSameDayAs: after)
        }
    }

    // MARK: - Token surgery

    /// Drops every token whose operator name and value satisfy `predicate`.
    ///
    /// Tokens are re-joined with single spaces, so a query with runs of
    /// whitespace comes back normalised. That is visible and harmless — and the
    /// alternative, splicing by range, would need a second tokeniser that
    /// tracked offsets and could disagree with the parser's.
    static func removingTokens(
        in raw: String, where predicate: (_ name: String, _ value: String) -> Bool
    ) -> String {
        SearchQuery.tokenize(raw.trimmingCharacters(in: .whitespacesAndNewlines))
            .filter { token in
                guard let (name, value) = split(token) else { return true }

                return predicate(name, value) == false
            }
            .joined(separator: " ")
    }

    /// An operator name and value, by the parser's own rules: first colon only,
    /// name case-folded, quotes stripped from the value.
    private static func split(_ token: String) -> (name: String, value: String)? {
        guard token.contains(":") else { return nil }

        let parts = token.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)

        return (
            parts[0].trimmingCharacters(in: .whitespaces).lowercased(),
            String(parts.count > 1 ? parts[1] : "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        )
    }

    private static func appending(_ token: String, to raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        return trimmed.isEmpty ? token : "\(trimmed) \(token)"
    }

    /// Fixed locale: this produces a token the parser reads back, not a date
    /// shown in someone's regional format.
    private static let iso: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"

        return formatter
    }()
}
