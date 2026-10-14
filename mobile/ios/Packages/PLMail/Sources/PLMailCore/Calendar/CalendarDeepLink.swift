import Foundation
public import JMAPKit

/// The rules for arriving at the calendar from **outside the app**: a Spotlight
/// result, an App Intent, a Handoff continuation, a restored window.
///
/// **Pure and `static` on purpose.** `App/` has no unit-test target, and every
/// one of these routes is a path a compiler cannot check and `swift test`
/// cannot reach through a view — the shell only ever binds a system callback to
/// one of these functions. The same shape as `MailSpotlightIndex`'s planners,
/// and for the same reason: the decision is testable here, the plumbing is a
/// line in `RootView`.
///
/// Nothing here reads a store, a network or a clock it was not handed. Every
/// answer is derived from ids and a day, because that is all a system callback
/// ever carries.
public enum CalendarDeepLink {
    /// The two ids behind a Spotlight identifier, typed.
    ///
    /// Thin over ``CalendarSpotlightIndex/ids(forUID:)`` so that the shell
    /// never builds a `CalendarEventID` out of a raw string by hand — the id it
    /// gets back is the *occurrence* id, which `CalendarEvent/set` refuses, and
    /// keeping the conversion in one place is what stops it being mistaken for
    /// a series id at the far end.
    public static func occurrence(
        forSpotlightUID uid: String
    ) -> (accountKey: String, occurrenceID: CalendarEventID)? {
        guard let ids = CalendarSpotlightIndex.ids(forUID: uid) else { return nil }

        return (ids.accountKey, CalendarEventID(rawValue: ids.occurrenceID))
    }

    /// The day a cached occurrence should be shown on.
    ///
    /// Read off the **wall clock**, never off `startsAt`. The resolved instant
    /// is a projection against one zone kept for ordering, so anchoring a grid
    /// on it puts an event booked in another zone on the wrong day for anybody
    /// whose device disagrees — which is precisely the reader who tapped a
    /// search result to find out when it was.
    ///
    /// Nil when the stored wall clock does not parse, which means a row written
    /// by a different build: guessing at it would open the calendar on a day
    /// the event is not on and claim the event is missing.
    public static func day(of occurrence: CalendarOccurrenceSnapshot) -> CalendarDay? {
        LocalDateTime(rawValue: occurrence.startLocal).map(CalendarDay.init)
    }

    /// The day a window scene should open on, given the key it was persisted
    /// with.
    ///
    /// **Falls back to `today` rather than failing.** A scene value is handed
    /// back after a relaunch that may be days later, and `CalendarDay(key:)`
    /// refuses anything a different build wrote; a window that opened on
    /// nothing at all would be a blank card in the app switcher with no way to
    /// recover it. Today is always a defensible answer for a calendar.
    public static func day(forSceneKey key: String?, today: CalendarDay) -> CalendarDay {
        key.flatMap(CalendarDay.init(key:)) ?? today
    }

    /// The day an intent's `Date` parameter names, in the device's zone.
    ///
    /// Nil in, today out: "open my calendar" with no date, and a Shortcuts
    /// parameter left unfilled, both arrive as nil and both mean now.
    public static func day(forIntentDate date: Date?, in zone: TimeZone) -> CalendarDay {
        CalendarDay(date ?? .now, in: zone)
    }

    /// What an intent's free-text title is worth keeping.
    ///
    /// Dictated titles arrive with padding and, when the parameter was skipped
    /// entirely, as an empty string. An editor prefilled with `" "` looks
    /// filled in and saves a nameless event, so whitespace-only becomes nil and
    /// the editor opens honestly blank.
    public static func title(forIntent raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
            trimmed.isEmpty == false
        else { return nil }

        return trimmed
    }
}
