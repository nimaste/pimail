import Foundation
import JMAPKit
import Testing

@testable import PLMailCore

@Suite("Duplicate collapse")
struct EventClusterTests {
    private func row(
        id: String,
        uid: String? = "meeting@plmail",
        calendar: String? = "1",
        name: String = "Work",
        colour: String? = "#336699",
        title: String = "Standup",
        start: String = "2026-08-03T09:00:00",
        end: String = "2026-08-03T09:15:00",
        zone: String? = "Europe/Berlin",
        isAllDay: Bool = false,
        isCancelled: Bool = false
    ) -> EventRow {
        CalendarFixture.row(
            id: id,
            start: start,
            end: end,
            uid: uid,
            calendar: calendar,
            calendarName: name,
            colour: colour,
            title: title,
            zone: zone,
            isAllDay: isAllDay,
            isCancelled: isCancelled
        )
    }

    @Test("two rows with the same uid and start on different calendars merge")
    func merges() throws {
        let clusters = EventClusterer.cluster([
            row(id: "10", calendar: "1", name: "Work"),
            row(id: "11", calendar: "2", name: "Personal"),
        ])

        #expect(clusters.count == 1)
        let cluster = try #require(clusters.first)
        #expect(cluster.isMerged)
        #expect(cluster.calendarNames == ["Work", "Personal"])
    }

    @Test("a disagreement over any of the five facts splits the whole group")
    func disagreementSplits() {
        for pair in [
            (row(id: "10", calendar: "1"), row(id: "11", calendar: "2", title: "Stand-up")),
            (
                row(id: "10", calendar: "1"),
                row(id: "11", calendar: "2", end: "2026-08-03T10:00:00")
            ),
            (
                row(id: "10", calendar: "1"),
                row(id: "11", calendar: "2", isAllDay: true)
            ),
            (
                row(id: "10", calendar: "1"),
                row(id: "11", calendar: "2", isCancelled: true)
            ),
        ] {
            let clusters = EventClusterer.cluster([pair.0, pair.1])

            #expect(clusters.count == 2)
            #expect(clusters.allSatisfy { $0.isMerged == false })
        }
    }

    @Test("three rows where one disagrees become three clusters, not a majority of two")
    func noMajorityWinner() {
        let clusters = EventClusterer.cluster([
            row(id: "10", calendar: "1"),
            row(id: "11", calendar: "2"),
            row(id: "12", calendar: "3", title: "Standup (moved)"),
        ])

        #expect(clusters.count == 3)
        #expect(clusters.allSatisfy { $0.members.count == 1 })
    }

    @Test("two rows on one calendar never merge, however much they agree")
    func sameCalendarNeverMerges() {
        let clusters = EventClusterer.cluster([
            row(id: "10", calendar: "1"),
            row(id: "11", calendar: "1"),
        ])

        #expect(clusters.count == 2)
    }

    @Test("a row with no uid never merges with anything, including another with none")
    func nullUIDNeverMerges() {
        let clusters = EventClusterer.cluster([
            row(id: "10", uid: nil, calendar: "1"),
            row(id: "11", uid: nil, calendar: "2"),
        ])

        #expect(clusters.count == 2)
    }

    @Test("a row with no calendar id never merges, because it cannot be shown to differ")
    func unknownCalendarNeverMerges() {
        let clusters = EventClusterer.cluster([
            row(id: "10", calendar: nil),
            row(id: "11", calendar: "2"),
        ])

        #expect(clusters.count == 2)
    }

    @Test("10:00 Europe/Berlin and 09:00 Europe/London are the same instant and merge")
    func acrossZones() {
        let clusters = EventClusterer.cluster([
            row(
                id: "10", calendar: "1", start: "2026-08-03T10:00:00",
                end: "2026-08-03T10:15:00", zone: "Europe/Berlin"),
            row(
                id: "11", calendar: "2", start: "2026-08-03T09:00:00",
                end: "2026-08-03T09:15:00", zone: "Europe/London"),
        ])

        #expect(clusters.count == 1)
    }

    @Test("a floating copy and a zoned copy of one meeting never merge")
    func floatingNeverMergesWithZoned() {
        let clusters = EventClusterer.cluster([
            row(id: "10", calendar: "1", zone: "Europe/Berlin"),
            row(id: "11", calendar: "2", zone: nil),
        ])

        #expect(clusters.count == 2)
    }

    @Test("two occurrences of one series on one day are two clusters, not one")
    func occurrencesAreNotDuplicates() {
        let clusters = EventClusterer.cluster([
            row(id: "10", calendar: "1", start: "2026-08-03T09:00:00", end: "2026-08-03T09:15:00"),
            row(id: "11", calendar: "1", start: "2026-08-03T16:00:00", end: "2026-08-03T16:15:00"),
        ])

        #expect(clusters.count == 2)
    }

    @Test("member order is the same whatever order storage hands the rows back in")
    func stableMemberOrder() throws {
        let forwards = EventClusterer.cluster([
            row(id: "9", calendar: "1", name: "Work"),
            row(id: "10", calendar: "2", name: "Personal"),
        ])
        let backwards = EventClusterer.cluster([
            row(id: "10", calendar: "2", name: "Personal"),
            row(id: "9", calendar: "1", name: "Work"),
        ])

        #expect(
            forwards.first?.members.map(\.occurrenceID) == [
                CalendarEventID(rawValue: "9"), CalendarEventID(rawValue: "10"),
            ])
        #expect(
            forwards.first?.members.map(\.occurrenceID)
                == backwards.first?.members.map(\.occurrenceID))
    }

    @Test("member order is numeric before lexicographic, so 9 precedes 10")
    func numericBeforeLexicographic() throws {
        let cluster = try #require(
            EventClusterer.cluster([
                row(id: "10", calendar: "2"),
                row(id: "9", calendar: "1"),
            ]).first)

        #expect(cluster.members.first?.occurrenceID.rawValue == "9")
    }

    @Test("a missing colour is kept as a slot rather than dropped")
    func nullsKept() throws {
        let cluster = try #require(
            EventClusterer.cluster([
                row(id: "10", calendar: "1", colour: nil),
                row(id: "11", calendar: "2", colour: "#aa0000"),
            ]).first)

        #expect(cluster.colours.count == 2)
        #expect(cluster.colours[0] == nil)
    }
}

@Suite("Calendar view modes")
struct CalendarViewModeTests {
    private var germanCalendar: Foundation.Calendar {
        var calendar = Foundation.Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        calendar.locale = Locale(identifier: "en_GB")

        return calendar
    }

    @Test("the month window is always 42 days, whatever month it is")
    func alwaysSixWeeks() {
        for month in 1...12 {
            let window = CalendarViewMode.month.window(
                anchor: CalendarDay(year: 2026, month: month, day: 15),
                using: germanCalendar
            )

            #expect(window.dayCount == 42)
        }
    }

    @Test("the month window starts on the locale's own first weekday")
    func weekStart() {
        var sunday = Foundation.Calendar(identifier: .gregorian)
        sunday.firstWeekday = 1

        let monday = CalendarViewMode.month.window(
            anchor: CalendarDay(year: 2026, month: 8, day: 15), using: germanCalendar)
        let american = CalendarViewMode.month.window(
            anchor: CalendarDay(year: 2026, month: 8, day: 15), using: sunday)

        #expect(monday.from == CalendarDay(year: 2026, month: 7, day: 27))
        #expect(american.from == CalendarDay(year: 2026, month: 7, day: 26))
    }

    @Test("month steps by a month rather than by its own 42 days")
    func monthSteps() {
        let anchor = CalendarDay(year: 2026, month: 1, day: 31)

        #expect(
            CalendarViewMode.month.step(from: anchor, by: 1)
                == CalendarDay(year: 2026, month: 2, day: 28))
        #expect(
            CalendarViewMode.month.step(from: anchor, by: 2)
                == CalendarDay(year: 2026, month: 3, day: 31))
    }

    @Test("agenda is a rolling list and does not step")
    func agendaDoesNotStep() {
        let anchor = CalendarDay(year: 2026, month: 8, day: 3)

        #expect(CalendarViewMode.agenda.step(from: anchor, by: 3) == anchor)
        #expect(CalendarViewMode.agenda.isPageable == false)
        #expect(
            CalendarViewMode.agenda.window(anchor: anchor, using: germanCalendar).dayCount == 30)
    }

    @Test("an unknown wire value degrades to the default rather than failing")
    func unknownWire() {
        #expect(CalendarViewMode.fromWire(nil) == .agenda)
        #expect(CalendarViewMode.fromWire("timeline") == .agenda)
        #expect(CalendarViewMode.fromWire("month-agenda") == .month)
        #expect(CalendarViewMode.fromWire("week") == .week)
    }

    @Test("a compact month persists the wire value the web uses for the same layout")
    func persistedWire() {
        #expect(CalendarViewMode.month.persistedWire(isCompactMonth: true) == "month-agenda")
        #expect(CalendarViewMode.month.persistedWire(isCompactMonth: false) == "month")
        #expect(CalendarViewMode.week.persistedWire(isCompactMonth: true) == "week")
    }

    @Test("a week heading drops the year both ends share, and the month too")
    func weekHeading() {
        let locale = Locale(identifier: "en_GB")
        let within = CalendarHeading.text(
            mode: .week,
            anchor: CalendarDay(year: 2026, month: 8, day: 5),
            locale: locale,
            calendar: germanCalendar,
            timeZone: .gmt
        )
        let acrossMonths = CalendarHeading.text(
            mode: .week,
            anchor: CalendarDay(year: 2026, month: 7, day: 29),
            locale: locale,
            calendar: germanCalendar,
            timeZone: .gmt
        )
        let acrossYears = CalendarHeading.text(
            mode: .week,
            anchor: CalendarDay(year: 2026, month: 12, day: 30),
            locale: locale,
            calendar: germanCalendar,
            timeZone: .gmt
        )

        // The near end carries only what the far end does not repeat.
        #expect(within.hasPrefix("3 – "))
        #expect(acrossMonths.hasPrefix("27 Jul – "))
        #expect(acrossYears.contains("2026") && acrossYears.contains("2027"))
    }
}

@Suite("Calendar colours")
struct CalendarColourTests {
    @Test("exactly six hex digits behind a hash, and nothing else")
    func strict() {
        #expect(CalendarColour(hex: "#336699") != nil)
        #expect(CalendarColour(hex: "#ABCDEF") != nil)
        #expect(CalendarColour(hex: "#abc") == nil)
        #expect(CalendarColour(hex: "336699") == nil)
        #expect(CalendarColour(hex: "#33669900") == nil)
        #expect(CalendarColour(hex: "rebeccapurple") == nil)
        #expect(CalendarColour(hex: "#33669g") == nil)
        #expect(CalendarColour(hex: "") == nil)
    }

    @Test("the channels are read in rrggbb order")
    func channels() throws {
        let colour = try #require(CalendarColour(hex: "#ff8000"))

        #expect(abs(colour.red - 1) < 0.001)
        #expect(abs(colour.green - 128.0 / 255) < 0.001)
        #expect(colour.blue == 0)
        #expect(colour.hex == "#ff8000")
    }

    @Test("a label colour is chosen for contrast rather than for taste")
    func labelContrast() throws {
        #expect(try #require(CalendarColour(hex: "#ffffff")).prefersDarkLabel)
        #expect(try #require(CalendarColour(hex: "#000000")).prefersDarkLabel == false)
    }
}
