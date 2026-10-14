import Foundation
import JMAPKit
import Testing

@testable import PLMailCore

/// The editor's rules, as pure functions.
///
/// Every one of these came from the Android implementation and every one is
/// load-bearing — several of them are the difference between an editor that
/// refuses the commonest event there is and one that does not.
@Suite("Event form")
struct EventFormTests {
    private let calendar = CalendarID("3")

    private func local(_ text: String) throws -> LocalDateTime {
        try #require(LocalDateTime(rawValue: text))
    }

    private func form(
        start: String = "2026-08-03T09:00:00",
        calendarID: CalendarID? = CalendarID("3")
    ) throws -> EventFormState {
        EventFormState(creatingAt: try local(start), calendarID: calendarID)
    }

    // MARK: - The two ordering rules

    /// "After" means something different on each side of the toggle, and this
    /// is the case that a single rule gets wrong: comparing the two midnights
    /// of a one-day all-day event would refuse the commonest all-day event
    /// there is.
    @Test("an all-day event starting and ending on the same day is valid")
    func allDaySameDayIsOneDay() throws {
        var state = try form()
        state.isAllDay = true
        state.endDate = state.startDate

        #expect(state.problem == nil)
        #expect(state.duration.wireValue == "P1D")
    }

    @Test("an all-day event is refused only when the end date precedes the start")
    func allDayEndBeforeStart() throws {
        var state = try form()
        state.isAllDay = true
        state.endDate = state.startDate.adding(days: -1)

        #expect(state.problem == .endsBeforeStart)

        state.endDate = state.startDate.adding(days: 2)

        #expect(state.problem == nil)
        #expect(state.duration.wireValue == "P3D")
    }

    @Test("a timed event ending exactly at its start is refused")
    func timedZeroLengthIsRefused() throws {
        var state = try form()
        state.endDate = state.startDate
        state.endTime = state.startTime

        #expect(state.problem == .doesNotEndAfterStart)
        #expect(state.isValid == false)
    }

    @Test("a timed event ending a minute after its start is valid")
    func timedOneMinuteIsValid() throws {
        var state = try form()
        state.endDate = state.startDate
        state.endTime = WallClockTime(hour: 9, minute: 1)

        #expect(state.problem == nil)
        #expect(state.duration.wireValue == "PT1M")
    }

    @Test("a timed event ending before its start is refused")
    func timedBackwardsIsRefused() throws {
        var state = try form()
        state.endDate = state.startDate
        state.endTime = WallClockTime(hour: 8, minute: 0)

        #expect(state.problem == .doesNotEndAfterStart)
    }

    /// The rule differs by more than a symbol: the same pair of values is legal
    /// on one side of the toggle and refused on the other.
    @Test("the same start and end is one day all-day and zero length timed")
    func theToggleChangesTheRule() throws {
        var state = try form()
        state.endDate = state.startDate
        state.endTime = state.startTime

        #expect(state.problem == .doesNotEndAfterStart)

        state.isAllDay = true

        #expect(state.problem == nil)
    }

    @Test("no calendar is its own problem, with its own sentence")
    func noCalendarIsRefused() throws {
        var state = try form(calendarID: nil)

        #expect(state.problem == .noCalendar)

        state.calendarID = calendar

        #expect(state.problem == nil)
    }

    @Test("an invalid form produces no draft at all")
    func invalidFormHasNoDraft() throws {
        var state = try form()
        state.endTime = state.startTime
        state.endDate = state.startDate

        #expect(state.draft(untitled: "Untitled") == nil)
    }

    // MARK: - What the pickers do

    /// Moving a meeting from Tuesday to Thursday moves the whole meeting. A
    /// start picker that left the end where it was would turn a one-hour
    /// meeting into a negative one and then refuse to save, with nothing on
    /// screen saying which field to correct.
    @Test("the start date picker shifts the end by the same number of days")
    func startDateShiftsTheEnd() throws {
        var state = try form(start: "2026-08-03T09:00:00")
        state.endDate = CalendarDay(year: 2026, month: 8, day: 5)

        state.startDate = CalendarDay(year: 2026, month: 8, day: 10)

        #expect(state.endDate == CalendarDay(year: 2026, month: 8, day: 12))

        // And backwards by the same rule.
        state.startDate = CalendarDay(year: 2026, month: 8, day: 8)

        #expect(state.endDate == CalendarDay(year: 2026, month: 8, day: 10))
    }

    @Test("the start date picker keeps the length across a month boundary")
    func startDateShiftAcrossMonths() throws {
        var state = try form(start: "2026-01-30T09:00:00")
        state.endDate = CalendarDay(year: 2026, month: 1, day: 31)

        state.startDate = CalendarDay(year: 2026, month: 3, day: 1)

        #expect(state.endDate == CalendarDay(year: 2026, month: 3, day: 2))
    }

    @Test("the end date picker moves only the end")
    func endDateMovesOnlyItself() throws {
        var state = try form(start: "2026-08-03T09:00:00")
        let start = state.startDate

        state.endDate = CalendarDay(year: 2026, month: 9, day: 1)

        #expect(state.startDate == start)
        #expect(state.endDate == CalendarDay(year: 2026, month: 9, day: 1))
    }

    // MARK: - Defaults

    /// An editor opened at 14:07 that proposes 14:07 asks the user to correct a
    /// time nobody would ever choose.
    @Test("a new event starts at the next whole hour")
    func nextWholeHour() throws {
        let zone = try #require(TimeZone(identifier: "Europe/Berlin"))
        let at1407 = try #require(local("2026-08-03T14:07:31").date(in: zone))

        #expect(
            EventFormState.nextWholeHour(after: at1407, in: zone).rawValue
                == "2026-08-03T15:00:00")
    }

    @Test("the next whole hour after 23:10 is midnight tomorrow, never hour 24")
    func nextWholeHourRollsTheDate() throws {
        let zone = try #require(TimeZone(identifier: "Europe/Berlin"))
        let at2310 = try #require(local("2026-08-03T23:10:00").date(in: zone))

        #expect(
            EventFormState.nextWholeHour(after: at2310, in: zone).rawValue
                == "2026-08-04T00:00:00")
    }

    /// `slotAt` already snapped the tap to the quarter hour, and rounding again
    /// would move a long press on the 14:15 line to 15:00 — the one thing the
    /// gesture promises not to do.
    @Test("a slot-created event is not rounded a second time")
    func slotCreatedIsNotRounded() throws {
        let state = try form(start: "2026-08-03T14:15:00")

        #expect(state.start.rawValue == "2026-08-03T14:15:00")
        #expect(state.duration.wireValue == "PT1H")
    }

    @Test("a new event lasts an hour and rolls the date when it starts at 23:30")
    func newEventLastsAnHour() throws {
        let state = try form(start: "2026-08-03T23:30:00")

        #expect(state.endDate == CalendarDay(year: 2026, month: 8, day: 4))
        #expect(state.duration.wireValue == "PT1H")
    }

    // MARK: - Loading an existing event

    private func series(
        start: String,
        duration: String?,
        allDay: Bool,
        recurring: Bool = false
    ) -> CalendarEventSnapshot {
        var snapshot = CalendarEventSnapshot(
            accountKey: "nas.local/7",
            eventID: CalendarEventID("41"),
            title: "Standup",
            startLocal: start
        )
        snapshot.calendarID = CalendarID("3")
        snapshot.duration = duration
        snapshot.showWithoutTime = allDay
        snapshot.isRecurring = recurring
        snapshot.locationName = "Kitchen"
        snapshot.eventDescription = "Bring numbers"

        return snapshot
    }

    /// The stored duration counts whole days from midnight, so the end lands on
    /// the midnight *after* the last day covered — drawing that date would say a
    /// one-day event lasts two.
    @Test("loading an all-day event draws the end a day earlier than it is stored")
    func allDayEndIsDrawnADayEarlier() {
        let state = EventFormState(
            editing: series(start: "2026-08-03T00:00:00", duration: "P1D", allDay: true))

        #expect(state.startDate == CalendarDay(year: 2026, month: 8, day: 3))
        #expect(state.endDate == CalendarDay(year: 2026, month: 8, day: 3))
        // …and it round-trips back to what was stored.
        #expect(state.duration.wireValue == "P1D")
    }

    @Test("a three-day all-day event round-trips through the form unchanged")
    func multiDayAllDayRoundTrips() {
        let state = EventFormState(
            editing: series(start: "2026-08-03T00:00:00", duration: "P3D", allDay: true))

        #expect(state.endDate == CalendarDay(year: 2026, month: 8, day: 5))
        #expect(state.duration.wireValue == "P3D")
    }

    @Test("a timed event round-trips through the form unchanged")
    func timedRoundTrips() {
        let state = EventFormState(
            editing: series(start: "2026-08-03T09:00:00", duration: "PT90M", allDay: false))

        #expect(state.startTime == WallClockTime(hour: 9, minute: 0))
        #expect(state.endTime == WallClockTime(hour: 10, minute: 30))
        #expect(state.duration.wireValue == "PT1H30M")
    }

    /// An absent duration is the server's own default, not zero. An event drawn
    /// with no height is an event nobody can tap.
    @Test("an event with no stored duration loads as an hour, or a day when all-day")
    func absentDurationTakesTheServerDefault() {
        let timed = EventFormState(
            editing: series(start: "2026-08-03T09:00:00", duration: nil, allDay: false))
        let allDay = EventFormState(
            editing: series(start: "2026-08-03T00:00:00", duration: nil, allDay: true))

        #expect(timed.duration.wireValue == "PT1H")
        #expect(allDay.duration.wireValue == "P1D")
    }

    /// An import can carry a zero-length all-day event the server would never
    /// emit; drawing it as ending the day before it begins would make it
    /// unsaveable without the user understanding why.
    @Test("a zero-length all-day event still draws as one day")
    func degenerateAllDayClamps() {
        let state = EventFormState(
            editing: series(start: "2026-08-03T00:00:00", duration: "PT0S", allDay: true))

        #expect(state.endDate == state.startDate)
        #expect(state.problem == nil)
    }

    @Test("a timed event spanning midnight is P1DT… rather than PT36H")
    func spanningMidnightKeepsTheDatePart() throws {
        var state = try form(start: "2026-08-03T20:00:00")
        state.endDate = CalendarDay(year: 2026, month: 8, day: 5)
        state.endTime = WallClockTime(hour: 8, minute: 0)

        // Twelve hours past two midnights, which is not the same as 60 hours on
        // the two days a year that are not 24 hours long.
        #expect(state.duration.wireValue == "P1DT12H")
    }

    // MARK: - Recurrence

    /// The single most important rule in the editor: the cache stores *whether*
    /// a series recurs and never the rule it recurs by, so an update built from
    /// the dropdown would flatten an elaborate imported rule — or clear it,
    /// since null on that property means *stop recurring*.
    @Test("recurrence is editable on create and read-only on edit")
    func recurrenceIsCreateOnly() throws {
        #expect(try form().mayEditRecurrence)

        let editing = EventFormState(
            editing: series(
                start: "2026-08-03T09:00:00", duration: "PT1H", allDay: false, recurring: true))

        #expect(editing.mayEditRecurrence == false)
        #expect(editing.isRecurringSeries)
    }

    @Test("an update never carries a recurrence rule, whatever the form holds")
    func updateNeverCarriesRecurrence() throws {
        var state = EventFormState(
            editing: series(
                start: "2026-08-03T09:00:00", duration: "PT1H", allDay: false, recurring: true))
        // Even if something set it — the type refuses to pass it on rather than
        // relying on every caller to remember.
        state.repeatRule = .weekly

        let draft = try #require(state.draft(untitled: "Untitled"))

        #expect(draft.recurrence == .never)
        #expect(draft.patch().namedProperties.contains("recurrenceRules") == false)
    }

    @Test("a create carries exactly the chosen frequency, and none for a one-off")
    func createCarriesTheChosenRule() throws {
        var state = try form()
        state.repeatRule = .weekly

        let repeating = try #require(state.draft(untitled: "Untitled"))

        #expect(repeating.recurrence.rule?.frequency == "weekly")

        state.repeatRule = .never

        #expect(try #require(state.draft(untitled: "Untitled")).recurrence.rule == nil)
    }

    @Test("every repeat choice maps to the frequency the web dropdown writes")
    func repeatVocabulary() {
        #expect(EventRepeat.never.frequency == nil)
        #expect(EventRepeat.daily.frequency == "daily")
        #expect(EventRepeat.weekly.frequency == "weekly")
        #expect(EventRepeat.monthly.frequency == "monthly")
        #expect(EventRepeat.yearly.frequency == "yearly")
        #expect(EventRepeat.allCases.count == 5)
    }

    // MARK: - The title

    /// JMAP refuses an empty title outright and the web stores the word, so
    /// matching it means an event created on a phone and one created in a
    /// browser are the same event.
    @Test("a blank title becomes the localised word rather than a refusal")
    func blankTitleBecomesUntitled() throws {
        var state = try form()
        state.title = "   \n "

        #expect(state.problem == nil)
        #expect(state.resolvedTitle(untitled: "Ohne Titel") == "Ohne Titel")
        #expect(try #require(state.draft(untitled: "Ohne Titel")).title == "Ohne Titel")
    }

    @Test("a title is trimmed rather than sent with the whitespace somebody typed")
    func titleIsTrimmed() throws {
        var state = try form()
        state.title = "  Standup  "

        #expect(state.resolvedTitle(untitled: "Untitled") == "Standup")
    }

    // MARK: - What reaches the wire

    /// The thirteen-property vocabulary, from the editor's end: the four
    /// refused properties are unrepresentable on the write types, and the zone
    /// is omitted so the calendar's own is used.
    @Test("a create names only properties the server accepts, and no time zone")
    func createBodyIsWithinTheVocabulary() throws {
        var state = try form(start: "2026-08-03T09:00:00")
        state.title = "Standup"
        state.location = "Kitchen"
        state.notes = "Bring numbers"
        state.repeatRule = .weekly

        let draft = try #require(state.draft(untitled: "Untitled"))
        let encoded = try JSONEncoder().encode(draft.newEvent())
        let json = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        let body = try #require(json)

        #expect(body["title"] as? String == "Standup")
        #expect(body["start"] as? String == "2026-08-03T09:00:00")
        #expect(body["duration"] as? String == "PT1H")
        #expect(body["calendarId"] as? String == "3")
        #expect(body["description"] as? String == "Bring numbers")
        // **Omitted, not null.** Absent means the calendar's own zone; an
        // explicit null would be floating time, which is a different event.
        #expect(body.keys.contains("timeZone") == false)
        // Never sent, and unrepresentable on the type.
        #expect(body.keys.contains("participants") == false)
        #expect(body.keys.contains("alerts") == false)
        #expect(body.keys.contains("links") == false)
        #expect(body.keys.contains("privacy") == false)
        // Absent on a create rather than false: an omitted key cannot be
        // mistaken for a client trying to clear something.
        #expect(body.keys.contains("showWithoutTime") == false)
    }

    @Test("an all-day create sends showWithoutTime and a whole-day duration")
    func allDayCreateBody() throws {
        var state = try form(start: "2026-08-03T09:00:00")
        state.isAllDay = true
        state.endDate = state.startDate.adding(days: 1)

        let draft = try #require(state.draft(untitled: "Untitled"))
        let body = try #require(
            try JSONSerialization.jsonObject(
                with: try JSONEncoder().encode(draft.newEvent())) as? [String: Any])

        // Midnight, because the time controls are not drawn for an all-day
        // event and any other value would be a decision nobody made.
        #expect(body["start"] as? String == "2026-08-03T00:00:00")
        #expect(body["duration"] as? String == "P2D")
        #expect(body["showWithoutTime"] as? Bool == true)
    }

    @Test("an update names no uid, no time zone and no recurrence overrides")
    func patchStaysWithinTheVocabulary() throws {
        var state = EventFormState(
            editing: series(start: "2026-08-03T09:00:00", duration: "PT1H", allDay: false))
        state.title = "Standup (moved)"

        let named = try #require(state.draft(untitled: "Untitled")).patch().namedProperties

        #expect(named.contains("title"))
        #expect(named.contains("start"))
        #expect(named.contains("duration"))
        #expect(named.contains("calendarId"))
        #expect(named.contains("uid") == false)
        #expect(named.contains("timeZone") == false)
        #expect(named.contains("recurrenceRules") == false)
        // Naming it replaces the whole map, dropping every other exception on
        // the series.
        #expect(named.contains("recurrenceOverrides") == false)
        // No key may contain a `/`: that is a JSON-pointer path and the server
        // refuses one with `invalidPatch`.
        #expect(named.allSatisfy { $0.contains("/") == false })
    }

    @Test("clearing a location and a description sends null rather than an empty string")
    func clearedFieldsAreNulled() throws {
        var state = EventFormState(
            editing: series(start: "2026-08-03T09:00:00", duration: "PT1H", allDay: false))
        state.location = ""
        state.notes = ""

        let draft = try #require(state.draft(untitled: "Untitled"))
        let body = try #require(
            try JSONSerialization.jsonObject(
                with: try JSONEncoder().encode(draft.patch())) as? [String: Any])

        #expect(body["locations"] is NSNull)
        #expect(body["description"] is NSNull)
    }
}

/// The one place a wall clock meets a `Date`.
///
/// A `DatePicker` has no other currency, so the editor converts — and a day
/// built in one zone and read back in another is the day before or after for
/// everybody whose offset crosses midnight. The failure is invisible to whoever
/// wrote the code and obvious to a user twelve hours away, which is why this
/// sweeps a whole year in zones east and west of UTC.
@Suite("Wall clock pickers")
struct WallClockDateTests {
    private static let zones = [
        "UTC",
        // East: +12/+13 with a DST change, and the +12:45 offset that catches
        // anything assuming whole hours.
        "Pacific/Auckland",
        "Pacific/Chatham",
        "Asia/Kolkata",
        // West, including a zone whose DST transition is at midnight — the day
        // on which 00:00 does not exist at all.
        "America/Los_Angeles",
        "America/Santiago",
    ]

    @Test("a day survives a round trip through a Date in every zone, every day of a year")
    func dayNeverShifts() throws {
        for name in Self.zones {
            let zone = try #require(TimeZone(identifier: name))
            var day = CalendarDay(year: 2026, month: 1, day: 1)

            for _ in 0..<366 {
                let asDate = WallClockDate.date(day: day, time: .midnight, in: zone)

                #expect(
                    WallClockDate.day(of: asDate, in: zone) == day,
                    "\(name): \(day) moved through a Date")

                day = day.adding(days: 1)
            }
        }
    }

    @Test("a wall clock survives a round trip at every quarter hour, in every zone")
    func timeNeverShifts() throws {
        // Deliberately a day with no transition in any of these zones, because
        // an hour that does not exist is a separate, documented case.
        let day = CalendarDay(year: 2026, month: 6, day: 15)

        for name in Self.zones {
            let zone = try #require(TimeZone(identifier: name))

            for minute in stride(from: 0, to: 24 * 60, by: 15) {
                let time = WallClockTime(hour: minute / 60, minute: minute % 60)
                let asDate = WallClockDate.date(day: day, time: time, in: zone)

                #expect(WallClockDate.time(of: asDate, in: zone) == time, "\(name): \(time)")
                #expect(WallClockDate.day(of: asDate, in: zone) == day, "\(name): \(time)")
            }
        }
    }

    /// Santiago's clocks go forward at midnight, so 00:00 does not exist on
    /// that day. A picker that could not represent the date would drop the
    /// control; the day is what must survive, not the hour.
    @Test("a day whose midnight does not exist still keeps its date")
    func midnightGapKeepsTheDay() throws {
        let zone = try #require(TimeZone(identifier: "America/Santiago"))
        let day = CalendarDay(year: 2026, month: 9, day: 6)
        let asDate = WallClockDate.date(day: day, time: .midnight, in: zone)

        #expect(WallClockDate.day(of: asDate, in: zone) == day)
    }

    /// The east/west assertion the brief asks for, stated as one fact: the same
    /// form values produce the same wire strings wherever the device is.
    @Test("the wire value of a form does not depend on the device's zone")
    func theWireValueIsZoneFree() throws {
        var sent: Set<String> = []

        for name in Self.zones {
            let zone = try #require(TimeZone(identifier: name))
            let day = CalendarDay(year: 2026, month: 8, day: 3)
            let asDate = WallClockDate.date(
                day: day, time: WallClockTime(hour: 9, minute: 0), in: zone)

            let start = try #require(LocalDateTime(rawValue: "2026-08-03T09:00:00"))
            var state = EventFormState(creatingAt: start, calendarID: CalendarID("3"))
            state.startDate = WallClockDate.day(of: asDate, in: zone)
            state.startTime = WallClockDate.time(of: asDate, in: zone)

            sent.insert(state.start.rawValue)
        }

        #expect(sent == ["2026-08-03T09:00:00"])
    }
}
