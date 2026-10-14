import Foundation
public import JMAPKit

/// The span a view is asking about: **half-open**, `from` included and `to`
/// excluded.
///
/// Half-open because the wire is — `CalendarEvent/query`'s `after` is inclusive
/// and `before` exclusive. A window closed at both ends has to add and subtract
/// a day at every boundary, and that arithmetic is what puts an event on the
/// wrong side of a month.
///
/// **One window is one request.** A week is a seven-day window, not seven
/// day-windows: `expandRecurrences` exists precisely so that a visible span
/// costs one round trip whatever recurs inside it, against a machine that is
/// somebody's Raspberry Pi running a single PHP worker pool.
public struct CalendarWindow: Hashable, Sendable {
    /// The first day, included.
    public let from: CalendarDay
    /// The day **after** the last, excluded.
    public let to: CalendarDay

    /// A hard ceiling, and an honesty cap rather than a performance one: an
    /// expanded query counts *occurrences*, so a daily standup over a decade is
    /// thousands of ids paged a hundred at a time against a server advertising
    /// four concurrent requests.
    public static let maxDays = 366

    /// The client's own conservative horizon line, either side of today.
    ///
    /// The server actually materialises `-1 year` / `+2 years`, but those are
    /// **opaque PHP relative-date expressions** that nothing here may parse —
    /// so the client clamps to a line it chose itself and reports the clamp.
    /// A window in the server's second year is therefore clamped and reported
    /// as possibly incomplete when it was in fact answerable: saying "there may
    /// be more" about a full month is a smaller lie than a month that silently
    /// stops.
    public static let guaranteedDays = 365

    /// Nil rather than a trap for an empty, inverted or over-long window, so a
    /// bad anchor from a restored preference is a state to report rather than a
    /// crash on launch.
    public init?(from: CalendarDay, to: CalendarDay) {
        guard from < to else { return nil }
        guard from.days(until: to) <= Self.maxDays else { return nil }

        self.from = from
        self.to = to
    }

    /// For windows whose length is fixed by construction — a day, a week, the
    /// 42-day month grid, a year — where the failable initialiser would force
    /// every view mode to answer an optional it cannot produce.
    init(unchecked from: CalendarDay, to: CalendarDay) {
        self.from = from
        self.to = to
    }

    /// Days covered. `to` is excluded, so a single day is 1.
    public var dayCount: Int { from.days(until: to) }

    /// Every day in the window, in order — what a grid iterates.
    public var days: [CalendarDay] {
        guard dayCount > 0 else { return [] }

        return (0..<dayCount).map { from.adding(days: $0) }
    }

    public func contains(_ day: CalendarDay) -> Bool { day >= from && day < to }

    /// Whether two windows cover the same days, which is what decides whether a
    /// refresh is worth making at all.
    public func covers(_ other: CalendarWindow) -> Bool {
        from <= other.from && to >= other.to
    }

    // MARK: - The horizon clamp

    /// A window trimmed to the client's own guaranteed horizon, and whether the
    /// trim happened.
    public struct Clamped: Hashable, Sendable {
        /// Nil when the clamp left nothing at all — a year view scrolled to
        /// 2034. The refresh reports that rather than sending a query the
        /// server refuses **whole** with `cannotCalculateOccurrences`.
        public let window: CalendarWindow?

        /// True does not mean anything is missing. It means the client cannot
        /// promise nothing is — a different sentence, and the only honest one
        /// available while `materialisedHorizon` is a string nothing may parse.
        public let mayBeIncomplete: Bool
    }

    /// Clamps to `today ± ``guaranteedDays```.
    ///
    /// Done **before** the query rather than after: an expanded window reaching
    /// past what the server has materialised is refused whole, not answered
    /// short, so a client that asked optimistically and trimmed the answer
    /// would get no answer at all.
    public func clamped(around today: CalendarDay) -> Clamped {
        let earliest = today.adding(days: -Self.guaranteedDays)
        let latest = today.adding(days: Self.guaranteedDays)

        let start = max(from, earliest)
        let end = min(to, latest)
        let wasTrimmed = start != from || end != to

        guard start < end else { return Clamped(window: nil, mayBeIncomplete: true) }

        return Clamped(
            window: CalendarWindow(unchecked: start, to: end),
            mayBeIncomplete: wasTrimmed
        )
    }

    // MARK: - Wire bounds

    /// The `after`/`before` pair to send, as **UTC instants** and as a
    /// deliberate union of two readings of the same window.
    ///
    /// `after` takes the **earlier** of the window's local midnight resolved
    /// against `zone` and that same midnight read as though it were already
    /// UTC; `before` takes the **later**. An event the server holds as an
    /// instant is bounded by the first, and one it holds as a wall clock —
    /// every all-day event, and anything imported with an explicit null zone —
    /// by the second. A single query has to reach both, and the two disagree by
    /// exactly the device's offset.
    ///
    /// The cost is at most a day's events at each edge, which placement drops.
    /// The alternative is a floating event at 23:00 on the window's last day
    /// never being asked for at all.
    ///
    /// Both ends are ``UTCDate`` and cannot be spelled any other way. A naive
    /// local window is what swept freshly created events out of Android's
    /// cache: the server parses both ends with `new DateTimeImmutable($value)`
    /// and converts to UTC, so an unsuffixed local time is read in the
    /// *server's* default zone.
    public func fetchBounds(in zone: TimeZone) -> (after: UTCDate, before: UTCDate) {
        let fromZoned = from.startOfDay(in: zone)
        let fromNaive = from.startOfDay(in: .gmt)
        let toZoned = to.startOfDay(in: zone)
        let toNaive = to.startOfDay(in: .gmt)

        return (
            after: UTCDate(min(fromZoned, fromNaive)),
            before: UTCDate(max(toZoned, toNaive))
        )
    }
}
