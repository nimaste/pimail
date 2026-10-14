import Foundation

/// Searches this person has run before.
///
/// Local by definition. The server is never told what was typed into the search
/// field — a query is a request, not a record — and there is no JMAP method
/// that would store one. It is also not reconstructible from anything, which is
/// why it lives in `UserDefaults` rather than the SwiftData store, whose
/// standing rule is that everything in it can be fetched again and may
/// therefore be deleted on any migration failure. `RemoteContentPolicy` sits
/// outside the store for the same reason.
public struct RecentSearches {
    private static let key = "de.plmail.recentSearches"

    /// Enough to be worth having, few enough that the list stays a shortcut
    /// rather than a history someone has to scroll through on a phone.
    public static let limit = 10

    /// `nonisolated(unsafe)` because `UserDefaults` is not `Sendable` but is
    /// documented as thread-safe, and this is a thin wrapper over it. The same
    /// trade as `RemoteContentPolicy`: an actor here would put an `await` in
    /// the path that draws a suggestion list on a keystroke.
    private nonisolated(unsafe) let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Most recent first.
    public func all() -> [String] {
        defaults.stringArray(forKey: Self.key) ?? []
    }

    /// Records a query that was actually run.
    ///
    /// An earlier identical search is moved to the front rather than
    /// duplicated: running the same query twice should not fill the list with
    /// it. The comparison is case-insensitive because `From:Ada` and `from:ada`
    /// are the same search to the parser, and keeping both would offer someone
    /// a choice that isn't one.
    public func record(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmed.isEmpty == false else { return }

        var kept = all().filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
        kept.insert(trimmed, at: 0)

        defaults.set(Array(kept.prefix(Self.limit)), forKey: Self.key)
    }

    /// Drops one entry, for a swipe on the suggestion row.
    public func forget(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        defaults.set(
            all().filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame },
            forKey: Self.key)
    }

    public func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}
