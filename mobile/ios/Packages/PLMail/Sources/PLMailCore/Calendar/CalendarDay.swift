import Foundation
public import JMAPKit

/// One calendar day, as year-month-day and **nothing else**.
///
/// A `Date` cannot play this part. A day is what a grid draws a column for and
/// what a heading names, and both of those are answered before any zone is
/// known — while a `Date` is an instant, so "the 5th" held as one is only the
/// 5th in the zone it was built in and becomes the 4th the moment it is read
/// somewhere else. That is the bug that puts an event in the wrong month cell
/// for anybody east of the machine that computed the grid.
///
/// Arithmetic here is calendrical and zone-free on purpose: adding a day to the
/// 27th of March is the 28th of March in every zone, whereas adding 86,400
/// seconds to an instant is not the same wall clock on the two days a year that
/// are not 24 hours long.
public struct CalendarDay: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// The day this instant falls on **in `zone`**, which is the only sense in
    /// which an instant has a day at all.
    public init(_ date: Date, in zone: TimeZone) {
        let parts = Self.arithmetic(in: zone).dateComponents([.year, .month, .day], from: date)

        self.init(year: parts.year ?? 0, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    /// The day part of a JSCalendar `LocalDateTime`, which already is a wall
    /// clock and therefore needs no zone to have a date.
    public init(_ local: LocalDateTime) {
        self.init(
            year: local.components.year ?? 0,
            month: local.components.month ?? 1,
            day: local.components.day ?? 1
        )
    }

    /// `yyyy-MM-dd`, the spelling `StoredCalendarOccurrence.dayKey` holds.
    ///
    /// Fixed width and zero-padded, which is what makes a string comparison of
    /// two keys chronological and lets a day view be one indexed read rather
    /// than a predicate doing date arithmetic in SQLite.
    public var key: String {
        Self.pad(year, 4) + "-" + Self.pad(month, 2) + "-" + Self.pad(day, 2)
    }

    /// Fails rather than substituting today, because a key that does not parse
    /// is a cache written by a different build and guessing at it would draw
    /// somebody's Tuesday on a Wednesday.
    public init?(key: String) {
        let parts = key.split(separator: "-", omittingEmptySubsequences: false)

        guard parts.count == 3,
            parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
            let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }

        self.init(year: year, month: month, day: day)
    }

    public var description: String { key }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    // MARK: - Arithmetic

    /// Midnight at the start of this day, in `zone`.
    ///
    /// Optional-free by falling back to the noon of the same day rolled back:
    /// on a spring-forward day in a zone whose transition happens at midnight
    /// — Santiago does this — 00:00 does not exist, and `Calendar.date(from:)`
    /// answers nil. A day that cannot be turned into an instant would drop a
    /// whole column out of a week, so the fallback is the first instant that
    /// *does* exist on that day, which is what every calendar app draws.
    public func startOfDay(in zone: TimeZone) -> Date {
        let calendar = Self.arithmetic(in: zone)
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day

        if let midnight = calendar.date(from: components) { return midnight }

        components.hour = 12

        guard let noon = calendar.date(from: components) else { return .distantPast }

        return calendar.startOfDay(for: noon)
    }

    /// `days` later, calendrically. Negative goes back.
    public func adding(days: Int) -> CalendarDay {
        guard days != 0 else { return self }

        let calendar = Self.arithmetic(in: .gmt)
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day

        guard let base = calendar.date(from: components),
            let moved = calendar.date(byAdding: .day, value: days, to: base)
        else { return self }

        return CalendarDay(moved, in: .gmt)
    }

    /// `months` later, **clamped to the end of the target month**.
    ///
    /// A month view steps by a month and not by its own 42 days, or paging
    /// through a year skips a fortnight every time. Foundation's own clamping
    /// is what makes 31 January plus one month land on 28 February rather than
    /// rolling into March.
    public func adding(months: Int) -> CalendarDay {
        guard months != 0 else { return self }

        let calendar = Self.arithmetic(in: .gmt)
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day

        guard let base = calendar.date(from: components),
            let moved = calendar.date(byAdding: .month, value: months, to: base)
        else { return self }

        return CalendarDay(moved, in: .gmt)
    }

    /// Whole days from `self` to `other`, positive when `other` is later.
    public func days(until other: CalendarDay) -> Int {
        let calendar = Self.arithmetic(in: .gmt)

        guard let start = calendar.date(from: dateComponents),
            let end = calendar.date(from: other.dateComponents)
        else { return 0 }

        return calendar.dateComponents([.day], from: start, to: end).day ?? 0
    }

    /// 1 = Sunday, 7 = Saturday, matching `Foundation.Calendar.weekday`.
    ///
    /// Deliberately the platform's numbering rather than ISO's, because every
    /// consumer here is a `Foundation.Calendar` `firstWeekday`, which is also
    /// 1-based from Sunday. Two numberings in one file is how a week grid ends
    /// up starting on the wrong day in one locale only.
    public func weekday(using calendar: Foundation.Calendar) -> Int {
        var arithmetic = calendar
        arithmetic.timeZone = .gmt

        guard let date = arithmetic.date(from: dateComponents) else { return 1 }

        return arithmetic.component(.weekday, from: date)
    }

    /// The start of the week containing this day, honouring the locale's own
    /// `firstWeekday` — Monday in Germany, Sunday in the United States. Hard
    /// coding either draws a week that begins on a day nobody's calendar does.
    public func startOfWeek(using calendar: Foundation.Calendar) -> CalendarDay {
        let offset = (weekday(using: calendar) - calendar.firstWeekday + 7) % 7

        return adding(days: -offset)
    }

    /// The first of this month.
    public var startOfMonth: CalendarDay { CalendarDay(year: year, month: month, day: 1) }

    /// The first of January of this year.
    ///
    /// Built from the components rather than by subtracting days, because the
    /// day-of-year of a date is not a fixed number: a leap year would put the
    /// year view's first cell on 2 January every fourth time, and the error
    /// would only ever show up in February.
    public var startOfYear: CalendarDay { CalendarDay(year: year, month: 1, day: 1) }

    /// Midday of this day, as an instant, in `zone`.
    ///
    /// Used wherever a `Date` is needed only to be formatted as a date —
    /// midday exists on every day in every zone, whereas midnight does not.
    public func middayInstant(in zone: TimeZone) -> Date {
        startOfDay(in: zone).addingTimeInterval(12 * 3600)
    }

    var dateComponents: DateComponents {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day

        return components
    }

    /// A Gregorian calendar with a fixed zone, for arithmetic only.
    ///
    /// Never `Calendar.current`: the user's calendar identifier could be
    /// Buddhist or Japanese, and the wire is Gregorian, so an event stored as
    /// 2026-08-03 must not become Reiwa 8 on the way through a component
    /// round trip.
    static func arithmetic(in zone: TimeZone) -> Foundation.Calendar {
        var calendar = Foundation.Calendar(identifier: .gregorian)
        calendar.timeZone = zone

        return calendar
    }

    private static func pad(_ value: Int, _ width: Int) -> String {
        let digits = String(abs(value))
        let padding = String(repeating: "0", count: max(0, width - digits.count))

        return (value < 0 ? "-" : "") + padding + digits
    }
}

extension LocalDateTime {
    /// The day this wall clock falls on. No zone, because a wall clock has a
    /// date of its own.
    public var calendarDay: CalendarDay { CalendarDay(self) }

    /// Minutes since midnight of its own day, `0..<1440`.
    ///
    /// **Wall-clock minutes, never elapsed time.** A grid draws 24 labelled
    /// rows and a block has to land against the row whose label matches the
    /// clock the reader sees; deriving the offset from a difference of instants
    /// agrees on every day except the two a year that are not 24 hours long.
    public var minuteOfDay: Int {
        (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    /// Midnight at the start of `day`.
    public static func midnight(of day: CalendarDay) -> LocalDateTime {
        LocalDateTime(
            year: day.year, month: day.month, day: day.day, hour: 0, minute: 0, second: 0)
    }
}
