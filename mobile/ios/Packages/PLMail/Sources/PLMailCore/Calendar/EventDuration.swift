import Foundation
public import JMAPKit

/// An ISO 8601 duration as the wire spells it — `PT1H`, `PT15M`, `P1D`,
/// `P1DT2H30M`.
///
/// Kept in whole date parts and whole time parts rather than reduced to
/// seconds, and that separation is the whole point of the type. `P1D` is "the
/// same wall clock tomorrow" and `PT24H` is "twenty-four hours later"; they
/// differ by an hour on the two days a year that are not 24 hours long, and an
/// all-day event stored as `P1D` collapsed to 86,400 seconds ends at 23:00 on
/// a spring-forward day — which draws a one-day event as spilling out of its
/// own cell.
///
/// Foundation has no ISO 8601 duration parser, which is why
/// ``JMAPKit/CalendarEvent/duration`` is a `String` on the wire type and why
/// this lives here rather than there: JMAPKit's job is to carry the server's
/// own spelling untouched.
public struct EventDuration: Hashable, Sendable {
    /// Calendrical parts — added to a date, never to a clock.
    public var years: Int
    public var months: Int
    public var weeks: Int
    public var days: Int

    /// Clock parts — added to a wall clock, and allowed to roll into the next
    /// day.
    public var hours: Int
    public var minutes: Int
    public var seconds: Int

    /// What the server applies when a create names no duration: one hour, or
    /// one whole day for an all-day event.
    public static let hour = EventDuration(hours: 1)
    public static let day = EventDuration(days: 1)

    public init(
        years: Int = 0,
        months: Int = 0,
        weeks: Int = 0,
        days: Int = 0,
        hours: Int = 0,
        minutes: Int = 0,
        seconds: Int = 0
    ) {
        self.years = years
        self.months = months
        self.weeks = weeks
        self.days = days
        self.hours = hours
        self.minutes = minutes
        self.seconds = seconds
    }

    /// Whether this is a zero-length duration — a legal `PT0S`, and what a
    /// point-in-time event carries.
    public var isZero: Bool {
        years == 0 && months == 0 && weeks == 0 && days == 0
            && hours == 0 && minutes == 0 && seconds == 0
    }

    /// Strict. Anything that is not an ISO 8601 duration answers nil rather
    /// than zero, because a zero-length event and an unreadable one look
    /// identical on a grid and only one of them is worth reporting.
    ///
    /// Negative durations are refused: the server never emits one, and an event
    /// that ends before it starts is data to survive rather than geometry to
    /// compute from.
    public init?(_ text: String) {
        var characters = Array(text)

        guard characters.first == "P" else { return nil }

        characters.removeFirst()

        var isTime = false
        var digits = ""
        var parsed = EventDuration()
        var sawAny = false

        for character in characters {
            if character == "T" {
                guard isTime == false, digits.isEmpty else { return nil }
                isTime = true
                continue
            }

            if character.isNumber {
                digits.append(character)
                continue
            }

            guard let value = Int(digits) else { return nil }
            digits = ""
            sawAny = true

            switch (isTime, character) {
            case (false, "Y"): parsed.years += value
            case (false, "M"): parsed.months += value
            case (false, "W"): parsed.weeks += value
            case (false, "D"): parsed.days += value
            case (true, "H"): parsed.hours += value
            case (true, "M"): parsed.minutes += value
            case (true, "S"): parsed.seconds += value
            default: return nil
            }
        }

        guard digits.isEmpty, sawAny else { return nil }

        self = parsed
    }

    /// The wire spelling. `PT0S` for zero, because `P` alone is not a duration
    /// any parser accepts.
    public var wireValue: String {
        if isZero { return "PT0S" }

        var date = ""
        if years != 0 { date += "\(years)Y" }
        if months != 0 { date += "\(months)M" }
        if weeks != 0 { date += "\(weeks)W" }
        if days != 0 { date += "\(days)D" }

        var time = ""
        if hours != 0 { time += "\(hours)H" }
        if minutes != 0 { time += "\(minutes)M" }
        if seconds != 0 { time += "\(seconds)S" }

        return "P" + date + (time.isEmpty ? "" : "T" + time)
    }
}

extension LocalDateTime {
    /// This wall clock, `duration` later — **in wall-clock terms**.
    ///
    /// Date parts move the date and leave the clock alone, so a `P1D` event
    /// starting at 09:00 ends at 09:00 the next day whether or not the clocks
    /// changed overnight. That is what a calendar means by a day, and it is why
    /// this is not `Date + TimeInterval`.
    public func adding(_ duration: EventDuration) -> LocalDateTime {
        var day = calendarDay

        if duration.years != 0 { day = day.adding(months: duration.years * 12) }
        if duration.months != 0 { day = day.adding(months: duration.months) }
        if duration.weeks != 0 || duration.days != 0 {
            day = day.adding(days: duration.weeks * 7 + duration.days)
        }

        let clock =
            (components.hour ?? 0) * 3600 + (components.minute ?? 0) * 60
            + (components.second ?? 0)
            + duration.hours * 3600 + duration.minutes * 60 + duration.seconds

        // A clock part large enough to pass midnight rolls the date, which is
        // what `PT36H` means. Floor division rather than truncation, so a
        // negative total — only reachable from malformed stored data — moves
        // backwards rather than landing on hour −1.
        let dayShift = Int((Double(clock) / 86_400).rounded(.down))
        let withinDay = clock - dayShift * 86_400

        if dayShift != 0 { day = day.adding(days: dayShift) }

        return LocalDateTime(
            year: day.year,
            month: day.month,
            day: day.day,
            hour: withinDay / 3600,
            minute: (withinDay % 3600) / 60,
            second: withinDay % 60
        )
    }

    /// Where an event starting here and lasting `duration` ends.
    ///
    /// Nil `duration` is the server's own default — `PT1H`, or `P1D` when the
    /// event is all-day — rather than zero, because an event drawn with no
    /// height is an event nobody can tap.
    public func end(after duration: String?, isAllDay: Bool) -> LocalDateTime {
        let parsed = duration.flatMap(EventDuration.init) ?? (isAllDay ? .day : .hour)

        return adding(parsed)
    }
}
