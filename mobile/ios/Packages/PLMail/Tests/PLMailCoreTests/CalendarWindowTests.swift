import Foundation
import JMAPKit
import Testing

@testable import PLMailCore

@Suite("Calendar windows")
struct CalendarWindowTests {
    private let day = CalendarDay(year: 2026, month: 8, day: 3)

    @Test("a window is half-open, so a single day is one day and not two")
    func halfOpen() throws {
        let window = try #require(
            CalendarWindow(from: day, to: CalendarDay(year: 2026, month: 8, day: 4)))

        #expect(window.dayCount == 1)
        #expect(window.days == [day])
        #expect(window.contains(day))
        #expect(window.contains(CalendarDay(year: 2026, month: 8, day: 4)) == false)
    }

    @Test("an inverted or empty window is refused rather than drawn backwards")
    func inverted() {
        #expect(CalendarWindow(from: day, to: day) == nil)
        #expect(CalendarWindow(from: day, to: CalendarDay(year: 2026, month: 8, day: 2)) == nil)
    }

    @Test("a window longer than MAX_DAYS is refused")
    func tooLong() {
        let ok = CalendarWindow(from: day, to: day.adding(days: CalendarWindow.maxDays))
        let over = CalendarWindow(from: day, to: day.adding(days: CalendarWindow.maxDays + 1))

        #expect(ok != nil)
        #expect(over == nil)
    }

    @Test("the clamp trims to the guaranteed horizon and reports that it did")
    func clampReports() throws {
        let today = CalendarDay(year: 2026, month: 8, day: 3)
        let far = try #require(
            CalendarWindow(
                from: today.adding(days: 300),
                to: today.adding(days: 300 + 42)))

        let clamped = far.clamped(around: today)

        #expect(clamped.mayBeIncomplete == false)

        let beyond = try #require(
            CalendarWindow(from: today.adding(days: 360), to: today.adding(days: 360 + 42)))
        let trimmed = beyond.clamped(around: today)

        #expect(trimmed.mayBeIncomplete)
        #expect(trimmed.window?.to == today.adding(days: CalendarWindow.guaranteedDays))
    }

    @Test("a window entirely past the horizon leaves nothing to query")
    func clampedOut() throws {
        let today = CalendarDay(year: 2026, month: 8, day: 3)
        let window = try #require(
            CalendarWindow(from: today.adding(days: 900), to: today.adding(days: 930)))

        let clamped = window.clamped(around: today)

        #expect(clamped.window == nil)
        #expect(clamped.mayBeIncomplete)
    }

    @Test("the fetch bounds are the union of the zoned and the naive reading, east of UTC")
    func unionEast() throws {
        let zone = try #require(TimeZone(identifier: "Europe/Berlin"))
        let window = try #require(CalendarWindow(from: day, to: day.adding(days: 1)))
        let bounds = window.fetchBounds(in: zone)

        // Berlin is ahead of UTC, so its local midnight is the *earlier*
        // instant; the naive reading is the later one, and `before` takes it.
        #expect(bounds.after.date == day.startOfDay(in: zone))
        #expect(bounds.before.date == day.adding(days: 1).startOfDay(in: .gmt))
        #expect(bounds.after.date < bounds.before.date)
    }

    @Test("the fetch bounds are the union of the zoned and the naive reading, west of UTC")
    func unionWest() throws {
        let zone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let window = try #require(CalendarWindow(from: day, to: day.adding(days: 1)))
        let bounds = window.fetchBounds(in: zone)

        // Los Angeles is behind UTC, so the naive reading is the earlier one.
        #expect(bounds.after.date == day.startOfDay(in: .gmt))
        #expect(bounds.before.date == day.adding(days: 1).startOfDay(in: zone))
    }

    @Test("the union reaches at least the whole window in either reading")
    func unionCovers() throws {
        for name in ["Europe/Berlin", "America/Los_Angeles", "Pacific/Kiritimati", "UTC"] {
            let zone = try #require(TimeZone(identifier: name))
            let window = try #require(CalendarWindow(from: day, to: day.adding(days: 7)))
            let bounds = window.fetchBounds(in: zone)

            #expect(bounds.after.date <= day.startOfDay(in: zone))
            #expect(bounds.after.date <= day.startOfDay(in: .gmt))
            #expect(bounds.before.date >= day.adding(days: 7).startOfDay(in: zone))
            #expect(bounds.before.date >= day.adding(days: 7).startOfDay(in: .gmt))
        }
    }
}

@Suite("Calendar days")
struct CalendarDayTests {
    @Test("adding days is calendrical and crosses a spring-forward day unchanged")
    func springForward() throws {
        // 29 March 2026 is the European spring-forward day: 23 hours long.
        let before = CalendarDay(year: 2026, month: 3, day: 28)

        #expect(before.adding(days: 1) == CalendarDay(year: 2026, month: 3, day: 29))
        #expect(before.adding(days: 2) == CalendarDay(year: 2026, month: 3, day: 30))
    }

    @Test("adding a month off the 31st clamps rather than rolling into the next month")
    func monthClamp() {
        let january = CalendarDay(year: 2026, month: 1, day: 31)

        #expect(january.adding(months: 1) == CalendarDay(year: 2026, month: 2, day: 28))
        #expect(january.adding(months: 12) == CalendarDay(year: 2027, month: 1, day: 31))
    }

    @Test("the key round-trips and sorts chronologically as a string")
    func keys() throws {
        let day = CalendarDay(year: 2026, month: 8, day: 3)

        #expect(day.key == "2026-08-03")
        #expect(CalendarDay(key: "2026-08-03") == day)
        #expect(CalendarDay(key: "2026-8-3") == nil)
        #expect("2026-08-03" < "2026-08-10")
    }

    @Test("a day's start is a real instant even where midnight does not exist")
    func missingMidnight() throws {
        // Santiago's spring transition happens at midnight, so 00:00 on the
        // transition day is a wall clock that never occurs.
        let zone = try #require(TimeZone(identifier: "America/Santiago"))
        let day = CalendarDay(year: 2026, month: 9, day: 6)
        let start = day.startOfDay(in: zone)

        #expect(start != .distantPast)
        #expect(CalendarDay(start, in: zone) == day)
    }
}

@Suite("ISO durations")
struct EventDurationTests {
    @Test("the shapes the server actually sends parse")
    func parses() throws {
        #expect(EventDuration("PT1H") == EventDuration(hours: 1))
        #expect(EventDuration("PT15M") == EventDuration(minutes: 15))
        #expect(EventDuration("P1D") == EventDuration(days: 1))
        #expect(EventDuration("P1DT2H30M") == EventDuration(days: 1, hours: 2, minutes: 30))
        #expect(EventDuration("PT0S")?.isZero == true)
    }

    @Test("anything that is not a duration is nil rather than zero")
    func refuses() {
        #expect(EventDuration("") == nil)
        #expect(EventDuration("1H") == nil)
        #expect(EventDuration("P") == nil)
        #expect(EventDuration("PT1X") == nil)
        #expect(EventDuration("PT1") == nil)
    }

    @Test("P1D is the same wall clock tomorrow, not 24 hours later")
    func wallClockDay() throws {
        let start = try #require(LocalDateTime(rawValue: "2026-03-29T09:00:00"))
        let end = start.adding(EventDuration(days: 1))

        #expect(end.rawValue == "2026-03-30T09:00:00")
    }

    @Test("clock parts roll the date when they pass midnight")
    func rollsOver() throws {
        let start = try #require(LocalDateTime(rawValue: "2026-08-03T23:30:00"))

        #expect(start.adding(EventDuration(hours: 1)).rawValue == "2026-08-04T00:30:00")
        #expect(start.adding(EventDuration(minutes: 30)).rawValue == "2026-08-04T00:00:00")
    }

    @Test("an absent duration is the server's own default, never zero")
    func defaults() throws {
        let start = try #require(LocalDateTime(rawValue: "2026-08-03T09:00:00"))

        #expect(start.end(after: nil, isAllDay: false).rawValue == "2026-08-03T10:00:00")
        #expect(start.end(after: nil, isAllDay: true).rawValue == "2026-08-04T09:00:00")
    }
}
