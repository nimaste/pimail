import Foundation

/// The whole filter vocabulary `CalendarEvent/query` has: **three conditions
/// and no operators**.
///
/// A struct rather than the sealed hierarchy ``EmailFilter`` uses, because
/// there is nothing to compose. `FilterOperator` is refused outright with
/// `unsupportedFilter`, so AND/OR/NOT cannot be expressed and neither can a
/// second calendar — an OR of two windows is two queries a client can make.
/// Any condition other than these three is `unsupportedFilter` naming it.
///
/// The window is **mandatory**, which is why both ends are non-optional
/// initialiser parameters rather than optional conditions: occurrences are
/// materialised only to a horizon, so an unbounded query would look complete
/// while stopping at it, and the server's refusal is a bare `unsupportedFilter`
/// that does not say which end is missing.
public struct CalendarEventFilter: Hashable, Sendable, Encodable {
    /// **Inclusive**, and a **UTC instant** — not a local wall clock.
    ///
    /// The type is ``UTCDate`` rather than `String` on purpose, and this is the
    /// one thing about this method easiest to get wrong. The server parses both
    /// ends with `new DateTimeImmutable($value)` and converts to UTC, so a
    /// naive local spelling like `2026-08-01T00:00:00` is read in the
    /// *server's* default zone. A client that built its window from local
    /// midnights and dropped the `Z` asks for a window offset by the difference
    /// between two machines' zones — which sweeps events created moments
    /// earlier straight back out of the cache, because they fall in the gap.
    /// ``UTCDate`` cannot encode any other spelling.
    public var after: UTCDate

    /// **Exclusive**, same spelling — a half-open window. Closed at both ends
    /// would mean adding and subtracting a second at every boundary, which is
    /// the arithmetic that puts an event on the wrong side of a month.
    public var before: UTCDate

    /// Optional. There is no "in any of these calendars": filter one, or filter
    /// none. A calendar the user does not own yields an **empty result, not an
    /// error** — reporting `notFound` would confirm the id exists.
    public var inCalendar: CalendarID?

    public init(after: UTCDate, before: UTCDate, inCalendar: CalendarID? = nil) {
        self.after = after
        self.before = before
        self.inCalendar = inCalendar
    }

    /// Convenience for the common case of a window built from two ``Date``s.
    public init(after: Date, before: Date, inCalendar: CalendarID? = nil) {
        self.init(after: UTCDate(after), before: UTCDate(before), inCalendar: inCalendar)
    }
}
