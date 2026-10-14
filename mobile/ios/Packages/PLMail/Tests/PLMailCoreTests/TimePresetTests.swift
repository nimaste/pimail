import Foundation
import Testing

@testable import PLMailCore

/// The presets are the whole snooze UI and most of the send-later one, and
/// every one of them can land in the past if it is computed by adding
/// intervals instead of asking a calendar. A time in the past is not a small
/// bug: the snooze sweep wakes it immediately, and a message scheduled for a
/// moment already gone goes out at once — in both cases the gesture appears to
/// have done nothing, or worse.
@Suite("Time presets")
struct TimePresetTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }()

    private func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Europe/Berlin")
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)!
    }

    /// The invariant that matters most, over a whole week and both sides of
    /// the evening cutoff.
    @Test(
        "every offered preset is in the future",
        arguments: [
            "2026-07-27T07:00:00+02:00",  // Monday morning
            "2026-07-27T19:30:00+02:00",  // Monday evening, past the cutoff
            "2026-07-31T23:59:00+02:00",  // Friday, minutes before midnight
            "2026-08-01T09:00:00+02:00",  // Saturday
            "2026-08-02T21:00:00+02:00",  // Sunday night
        ]
    )
    func alwaysFuture(now iso: String) {
        let now = date(iso)

        for (preset, when) in TimePreset.available(from: now, calendar: calendar) {
            #expect(when > now, "\(preset.title) landed in the past")
        }
    }

    /// The evening slot exists for send-later, where the useful thing is
    /// landing after the recipient's working day rather than at the start of
    /// it. Same day as "tomorrow", ten hours later.
    @Test("tomorrow evening lands at 18:00 on the same day as tomorrow")
    func tomorrowEvening() throws {
        let now = date("2026-07-27T15:20:00+02:00")
        let evening = try #require(TimePreset.tomorrowEvening.date(from: now, calendar: calendar))
        let morning = try #require(TimePreset.tomorrow.date(from: now, calendar: calendar))

        #expect(calendar.component(.hour, from: evening) == 18)
        #expect(calendar.component(.minute, from: evening) == 0)
        #expect(calendar.isDate(evening, inSameDayAs: morning))
        #expect(evening > morning)
    }

    /// Held mail is the case where a weekend is wrong: Saturday morning is
    /// when nobody is reading. The two lists differ on purpose, so a preset
    /// quietly appearing in both would be a regression rather than tidying.
    @Test("send-later offers the evening and no weekend")
    func sendLaterChoices() {
        #expect(TimePreset.sendLaterChoices.contains(.tomorrowEvening))
        #expect(TimePreset.sendLaterChoices.contains(.thisWeekend) == false)
        #expect(TimePreset.snoozeChoices.contains(.thisWeekend))
        #expect(TimePreset.snoozeChoices.contains(.tomorrowEvening) == false)
    }

    /// Asking for a subset must not smuggle the rest back in through
    /// `allCases`, which is what the default argument uses.
    @Test("only the presets asked for are offered")
    func choicesAreRespected() {
        let offered = TimePreset.available(
            among: TimePreset.sendLaterChoices,
            // Midweek on purpose. On a Friday "this weekend" collides with
            // "tomorrow" and is dropped as a duplicate anyway, so a version
            // that ignored `choices` entirely would still pass.
            from: date("2026-07-29T09:00:00+02:00"),  // Wednesday
            calendar: calendar
        )

        #expect(offered.map(\.preset).contains(.thisWeekend) == false)
        #expect(Set(offered.map(\.preset)).isSubset(of: Set(TimePreset.sendLaterChoices)))
    }

    /// Past the evening hour there is no later today left. Offering it anyway
    /// is the one case that would silently mean "in a moment".
    @Test("later today disappears once the evening has passed")
    func laterTodayExpires() {
        let evening = date("2026-07-27T19:30:00+02:00")

        #expect(TimePreset.laterToday.date(from: evening, calendar: calendar) == nil)

        let morning = date("2026-07-27T07:00:00+02:00")

        #expect(TimePreset.laterToday.date(from: morning, calendar: calendar) != nil)
    }

    /// Landing at a fixed local hour is what separates "tomorrow morning" from
    /// "in 24 hours" — the second is what an interval-based version gives, and
    /// it drifts a little further from breakfast every time it is used.
    @Test("tomorrow lands at 08:00 local, not 24 hours out")
    func tomorrowIsMorning() throws {
        let now = date("2026-07-27T15:20:00+02:00")
        let when = try #require(TimePreset.tomorrow.date(from: now, calendar: calendar))

        #expect(calendar.component(.hour, from: when) == 8)
        #expect(calendar.component(.minute, from: when) == 0)
        #expect(calendar.component(.day, from: when) == 28)
    }

    /// On the weekend itself it has to mean the *next* one, or Saturday
    /// afternoon would offer a time that morning.
    @Test("this weekend on a Saturday means the following Saturday")
    func weekendFromWeekend() throws {
        let saturday = date("2026-08-01T14:00:00+02:00")
        let when = try #require(TimePreset.thisWeekend.date(from: saturday, calendar: calendar))

        #expect(when > saturday)
        #expect(calendar.component(.weekday, from: when) == 7)
        #expect(calendar.component(.day, from: when) == 8)
    }

    @Test("this weekend from midweek is the coming Saturday")
    func weekendFromMidweek() throws {
        let wednesday = date("2026-07-29T10:00:00+02:00")
        let when = try #require(TimePreset.thisWeekend.date(from: wednesday, calendar: calendar))

        #expect(calendar.component(.weekday, from: when) == 7)
        #expect(calendar.component(.day, from: when) == 1)
    }

    @Test("next week is always a Monday, and never today")
    func nextWeekIsMonday() throws {
        for iso in [
            "2026-07-27T09:00:00+02:00",  // Monday
            "2026-07-30T09:00:00+02:00",  // Thursday
            "2026-08-02T09:00:00+02:00",  // Sunday
        ] {
            let now = date(iso)
            let when = try #require(TimePreset.nextWeek.date(from: now, calendar: calendar))

            #expect(calendar.component(.weekday, from: when) == 2)
            #expect(when > now)
            #expect(calendar.isDate(when, inSameDayAs: now) == false)
        }
    }
}
