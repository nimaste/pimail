import Foundation

/// One event, flattened into what a widget can draw without a database.
///
/// A widget runs in another process with another sandbox, so it cannot open the
/// SwiftData store — see ``SharedMailState`` for why coordinating one SQLite
/// file across two processes is the wrong trade for a handful of values.
public struct SharedCalendarEvent: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String

    /// **The wall clock, already formatted**, because the app is the only side
    /// that knows the reader's locale settings and because a widget must not
    /// convert. A floating event is the same clock everywhere and an event in
    /// another zone is drawn against the clock its own zone names; a widget
    /// handed an instant and left to format it would quietly move both.
    public var timeText: String

    /// `#rrggbb`, or nil where the calendar published none. Nil rather than an
    /// invented grey, and **never the only carrier of meaning** — the title and
    /// the time say everything the swatch does not.
    public var colourHex: String?
    public var calendarName: String?
    public var isAllDay: Bool

    /// When this event starts and ends **as instants**, for scheduling alone.
    ///
    /// A widget knows exactly when its content changes, which almost no widget
    /// does, so its timeline is cut at real event boundaries rather than on a
    /// fifteen-minute cadence. These are a projection against the device's zone
    /// at the moment the app wrote them and must never be formatted for
    /// display — that is what ``timeText`` is for.
    public var startsAt: Date
    public var endsAt: Date

    public init(
        id: String,
        title: String,
        timeText: String,
        colourHex: String? = nil,
        calendarName: String? = nil,
        isAllDay: Bool = false,
        startsAt: Date,
        endsAt: Date
    ) {
        self.id = id
        self.title = title
        self.timeText = timeText
        self.colourHex = colourHex
        self.calendarName = calendarName
        self.isAllDay = isAllDay
        self.startsAt = startsAt
        self.endsAt = endsAt
    }
}

/// What a calendar widget is given, and when it was given it.
///
/// **Written only from the cache, by the app, while somebody was looking.** The
/// calendar has no `/changes`, no push and no delta — `state` is the literal
/// string `"fixed"` — so there is no mechanism by which a widget could refresh
/// itself against the server even if it were allowed to, and this audience runs
/// plMail on a Raspberry Pi with one PHP worker pool. A widget that reached for
/// a NAS would be a widget that shows a spinner whenever its owner is away from
/// home.
public struct SharedCalendarState: Codable, Equatable, Sendable {
    /// Today's events that have not finished yet, soonest first, capped at
    /// ``limit``.
    public var upcoming: [SharedCalendarEvent]

    /// The day these events belong to, as `yyyy-MM-dd`.
    ///
    /// **The honesty check.** A widget woken at 06:00 with yesterday's list has
    /// no way to tell from the events themselves that the day has turned; with
    /// this it can say "nothing loaded for today" instead of confidently
    /// drawing yesterday's standup.
    public var dayKey: String

    /// Whether the server this was written from publishes a calendar at all.
    ///
    /// False is a **supported** instance, not an error, and the widget says so
    /// rather than showing an empty day it cannot account for.
    public var hasCalendar: Bool

    public var updatedAt: Date

    /// Four, matching what a `.systemMedium` can show without shrinking text.
    ///
    /// Capped at the writing end rather than the drawing end so the shared
    /// value stays small: it is read by a process the system may wake dozens of
    /// times a day, and a year of events in `UserDefaults` would be paid for on
    /// every one of them.
    public static let limit = 4

    public init(
        upcoming: [SharedCalendarEvent] = [],
        dayKey: String = "",
        hasCalendar: Bool = false,
        updatedAt: Date = .now
    ) {
        self.upcoming = upcoming
        self.dayKey = dayKey
        self.hasCalendar = hasCalendar
        self.updatedAt = updatedAt
    }
}

/// Reads and writes ``SharedCalendarState`` through the app group.
///
/// A neighbour of ``SharedMailStore`` rather than a second mechanism, and
/// **blocked on exactly the same App Group**, which needs a paid Apple
/// developer account. In the Simulator a group container resolves *without* the
/// entitlement, so this looks like it works there and silently does nothing on
/// a device — which is why the widget states its own age and says what is
/// missing rather than drawing a confident empty day.
public enum SharedCalendarStore {
    private static let key = "sharedCalendarState"

    /// Falls back to this process's own defaults when the group is
    /// unavailable, so the app still works and only the widget goes stale.
    nonisolated(unsafe) private static let defaults =
        UserDefaults(suiteName: SharedMailStore.suiteName) ?? .standard

    public static func write(_ state: SharedCalendarState) {
        guard let data = try? JSONEncoder().encode(state) else { return }

        defaults.set(data, forKey: key)
    }

    public static func read() -> SharedCalendarState? {
        guard let data = defaults.data(forKey: key) else { return nil }

        return try? JSONDecoder().decode(SharedCalendarState.self, from: data)
    }

    /// Clears the shared copy on sign-out.
    ///
    /// The correctness requirement, not a nicety: a widget still naming
    /// yesterday's meetings after the account was removed leaks the previous
    /// user's calendar onto the home screen of whoever holds the device next.
    public static func clear() {
        defaults.removeObject(forKey: key)
    }
}
