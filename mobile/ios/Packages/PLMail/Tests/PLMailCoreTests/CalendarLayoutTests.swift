import Foundation
import JMAPKit
import Testing

@testable import PLMailCore

/// Builders shared by the layout and the clustering suites.
///
/// Force-unwrapping a literal `LocalDateTime` is what `Tests/.swift-format`
/// relaxes the rule for: a fixture that does not parse is a broken test, and
/// threading an optional through every builder would hide the assertions.
enum CalendarFixture {
    static func local(_ text: String) -> LocalDateTime {
        // swift-format-ignore: NeverForceUnwrap
        LocalDateTime(rawValue: text)!
    }

    static func row(
        id: String,
        start: String,
        end: String,
        uid: String? = "uid-1",
        calendar: String? = "1",
        calendarName: String? = "Work",
        colour: String? = "#336699",
        title: String = "Standup",
        zone: String? = "Europe/Berlin",
        isAllDay: Bool = false,
        isCancelled: Bool = false,
        sortInstant: Date = .distantPast
    ) -> EventRow {
        EventRow(
            occurrenceID: CalendarEventID(rawValue: id),
            seriesID: CalendarEventID(rawValue: id),
            calendarID: calendar.map { CalendarID(rawValue: $0) },
            calendarName: calendarName,
            colourHex: colour,
            uid: uid,
            title: title,
            start: local(start),
            end: local(end),
            timeZoneName: zone,
            isAllDay: isAllDay,
            isCancelled: isCancelled,
            sortInstant: sortInstant
        )
    }

    static func cluster(
        id: String,
        start: String,
        end: String,
        title: String = "Standup",
        isAllDay: Bool = false
    ) -> EventCluster {
        EventCluster(
            members: [row(id: id, start: start, end: end, title: title, isAllDay: isAllDay)])
    }
}

@Suite("Day grid layout")
struct DayGridLayoutTests {
    private let day = CalendarDay(year: 2026, month: 8, day: 3)

    private func place(_ clusters: [EventCluster]) -> [PlacedCluster] {
        DayGridLayout.place(clusters, on: day).timed
    }

    @Test("a block's top and height are fractions of the column, in wall-clock minutes")
    func fractions() throws {
        let placed = try #require(
            place([
                CalendarFixture.cluster(
                    id: "1", start: "2026-08-03T06:00:00", end: "2026-08-03T12:00:00")
            ])
            .first)

        #expect(abs(placed.top - 0.25) < 0.000_1)
        #expect(abs(placed.height - 0.25) < 0.000_1)
    }

    @Test("an event ending exactly at midnight fills to the bottom and is not continuing")
    func endsAtMidnight() throws {
        let placed = try #require(
            place([
                CalendarFixture.cluster(
                    id: "1", start: "2026-08-03T22:00:00", end: "2026-08-04T00:00:00")
            ]).first)

        #expect(placed.continuesAfter == false)
        #expect(abs(placed.top - 22.0 / 24) < 0.000_1)
        #expect(abs(placed.height - 2.0 / 24) < 0.000_1)
    }

    @Test("an event crossing midnight is clipped on both days and flagged on each")
    func crossesMidnight() throws {
        let cluster = CalendarFixture.cluster(
            id: "1", start: "2026-08-03T22:00:00", end: "2026-08-04T02:00:00")

        let first = try #require(DayGridLayout.place([cluster], on: day).timed.first)
        let second = try #require(
            DayGridLayout.place([cluster], on: day.adding(days: 1)).timed.first)

        #expect(first.continuesAfter)
        #expect(first.continuesBefore == false)
        #expect(abs(first.top + first.height - 1) < 0.000_1)

        #expect(second.continuesBefore)
        #expect(second.continuesAfter == false)
        #expect(second.top == 0)
        #expect(abs(second.height - 2.0 / 24) < 0.000_1)
    }

    @Test("a stay ending at midnight does not appear on the following day")
    func midnightEndIsNotTheNextDay() {
        let cluster = CalendarFixture.cluster(
            id: "1", start: "2026-08-01T00:00:00", end: "2026-08-03T00:00:00", isAllDay: true)

        #expect(
            DayGridLayout.place([cluster], on: CalendarDay(year: 2026, month: 8, day: 2))
                .allDay.count == 1)
        #expect(DayGridLayout.place([cluster], on: day).allDay.isEmpty)
    }

    @Test("an end before its start clamps to zero height rather than inverting")
    func inverted() throws {
        let placed = try #require(
            place([
                CalendarFixture.cluster(
                    id: "1", start: "2026-08-03T10:00:00", end: "2026-08-03T09:00:00")
            ]).first)

        #expect(placed.top > 0)
        #expect(placed.height > 0)
        #expect(placed.height < 0.001)
    }

    @Test("a 23:30 event on a spring-forward day stays inside its own day")
    func springForward() throws {
        let transition = CalendarDay(year: 2026, month: 3, day: 29)
        let cluster = CalendarFixture.cluster(
            id: "1", start: "2026-03-29T23:30:00", end: "2026-03-30T00:00:00")
        let placed = try #require(DayGridLayout.place([cluster], on: transition).timed.first)

        #expect(placed.continuesAfter == false)
        #expect(placed.top + placed.height <= 1.000_1)
    }

    @Test("a fall-back day draws the repeated hour as an overlap rather than a gap")
    func fallBack() {
        // 25 October 2026: 02:00–03:00 happens twice in Europe. Both copies are
        // wall clocks in the same hour, so they lane against each other.
        let placed = DayGridLayout.place(
            [
                CalendarFixture.cluster(
                    id: "1", start: "2026-10-25T02:00:00", end: "2026-10-25T02:30:00"),
                CalendarFixture.cluster(
                    id: "2", start: "2026-10-25T02:15:00", end: "2026-10-25T02:45:00"),
            ],
            on: CalendarDay(year: 2026, month: 10, day: 25)
        ).timed

        #expect(placed.count == 2)
        #expect(placed.allSatisfy { $0.lanes == 2 })
    }

    @Test("two non-overlapping events are two runs and each is full width")
    func separateRuns() {
        let placed = place([
            CalendarFixture.cluster(
                id: "1", start: "2026-08-03T09:00:00", end: "2026-08-03T10:00:00"),
            CalendarFixture.cluster(
                id: "2", start: "2026-08-03T10:00:00", end: "2026-08-03T11:00:00"),
        ])

        #expect(placed.count == 2)
        #expect(placed.allSatisfy { $0.lanes == 1 && $0.lane == 0 })
    }

    @Test("the longest of two events starting together takes lane 0")
    func longestFirst() throws {
        let placed = place([
            CalendarFixture.cluster(
                id: "2", start: "2026-08-03T09:00:00", end: "2026-08-03T09:15:00"),
            CalendarFixture.cluster(
                id: "1", start: "2026-08-03T09:00:00", end: "2026-08-03T12:00:00"),
        ])

        let long = try #require(
            placed.first { $0.cluster.representative.occurrenceID.rawValue == "1" })
        let short = try #require(
            placed.first { $0.cluster.representative.occurrenceID.rawValue == "2" })

        #expect(long.lane == 0)
        #expect(short.lane == 1)
    }

    @Test("a whole run shares one lane count so block edges line up")
    func sharedLaneCount() {
        let placed = place([
            CalendarFixture.cluster(
                id: "1", start: "2026-08-03T09:00:00", end: "2026-08-03T12:00:00"),
            CalendarFixture.cluster(
                id: "2", start: "2026-08-03T09:30:00", end: "2026-08-03T10:00:00"),
            CalendarFixture.cluster(
                id: "3", start: "2026-08-03T09:45:00", end: "2026-08-03T10:15:00"),
        ])

        #expect(placed.count == 3)
        #expect(Set(placed.map(\.lanes)) == [3])
    }

    @Test("a lane is reused once its previous occupant has ended")
    func greedyReuse() throws {
        let placed = place([
            CalendarFixture.cluster(
                id: "1", start: "2026-08-03T09:00:00", end: "2026-08-03T12:00:00"),
            CalendarFixture.cluster(
                id: "2", start: "2026-08-03T09:30:00", end: "2026-08-03T10:00:00"),
            CalendarFixture.cluster(
                id: "3", start: "2026-08-03T10:00:00", end: "2026-08-03T11:00:00"),
        ])

        let second = try #require(placed.first { $0.cluster.id.rawValue == "2" })
        let third = try #require(placed.first { $0.cluster.id.rawValue == "3" })

        #expect(second.lane == 1)
        #expect(third.lane == 1)
        #expect(Set(placed.map(\.lanes)) == [2])
    }

    @Test("a run closes at the first span starting at or after its running end")
    func runBoundary() {
        let placed = place([
            CalendarFixture.cluster(
                id: "1", start: "2026-08-03T09:00:00", end: "2026-08-03T10:00:00"),
            CalendarFixture.cluster(
                id: "2", start: "2026-08-03T09:30:00", end: "2026-08-03T10:30:00"),
            CalendarFixture.cluster(
                id: "3", start: "2026-08-03T10:30:00", end: "2026-08-03T11:00:00"),
        ])

        let lanes = Dictionary(
            uniqueKeysWithValues: placed.map { ($0.cluster.id.rawValue, $0.lanes) })

        #expect(lanes["1"] == 2)
        #expect(lanes["2"] == 2)
        #expect(lanes["3"] == 1)
    }

    @Test("an event with a free lane beside it is not widened to fill it")
    func neverWidened() throws {
        let placed = place([
            CalendarFixture.cluster(
                id: "1", start: "2026-08-03T09:00:00", end: "2026-08-03T12:00:00"),
            CalendarFixture.cluster(
                id: "2", start: "2026-08-03T09:30:00", end: "2026-08-03T10:00:00"),
        ])

        // Width is "this many things are happening at once", so both blocks
        // report two lanes even though the second frees its lane at 10:00.
        #expect(placed.allSatisfy { $0.lanes == 2 })
    }
}

@Suite("Tap-to-create slots")
struct SlotTests {
    @Test("a slot snaps down to the quarter hour, never up")
    func snapsDown() {
        // 10:14 is a tap just below the 10:15 line and must not become 10:15.
        #expect(DayGridLayout.slotAt(fraction: (10 * 60 + 14) / 1440.0) == 600)
        #expect(DayGridLayout.slotAt(fraction: (10 * 60 + 15) / 1440.0) == 615)
        #expect(DayGridLayout.slotAt(fraction: (9 * 60 + 59) / 1440.0) == 585)
    }

    @Test("a slot clamps at both ends rather than proposing 24:00")
    func clamps() {
        #expect(DayGridLayout.slotAt(fraction: -0.5) == 0)
        #expect(DayGridLayout.slotAt(fraction: 1.0) == 1425)
        #expect(DayGridLayout.slotAt(fraction: 2.0) == 1425)
    }

    @Test("a slot's wall clock lands on the day that was tapped")
    func slotStart() {
        let day = CalendarDay(year: 2026, month: 8, day: 3)
        let start = DayGridLayout.slotStart(on: day, fraction: (14 * 60 + 20) / 1440.0)

        #expect(start.rawValue == "2026-08-03T14:15:00")
    }
}

@Suite("Month cell planning")
struct MonthCellPlanTests {
    @Test("an iPad-sized cell carries titled chips")
    func chips() {
        let plan = MonthCellPlan(count: 3, height: 90, width: 150, rowHeight: 16)

        #expect(plan.chips == 3)
        #expect(plan.dots == 0)
        #expect(plan.overflow == 0)
    }

    @Test("a cell that cannot fit them all keeps a row for the overflow count")
    func overflow() {
        let plan = MonthCellPlan(count: 8, height: 60, width: 150, rowHeight: 16)

        #expect(plan.chips > 0)
        #expect(plan.chips < 8)
        #expect(plan.chips + plan.overflow == 8)
    }

    @Test("a phone-sized cell falls back to dots, and by measurement rather than idiom")
    func dots() {
        let plan = MonthCellPlan(count: 3, height: 30, width: 40, rowHeight: 16)

        #expect(plan.isDotsOnly)
        #expect(plan.dots + plan.overflow == 3)
    }

    @Test("an accessibility text size turns the same cell from chips into dots")
    func accessibilitySize() {
        let normal = MonthCellPlan(count: 2, height: 40, width: 150, rowHeight: 16)
        let large = MonthCellPlan(count: 2, height: 40, width: 150, rowHeight: 44)

        // The same cell, the same events, a different answer — which is the
        // whole point of planning from measurement rather than from idiom.
        #expect(normal.chips == 2)
        #expect(large.isDotsOnly)
        #expect(large.dots + large.overflow == 2)
    }

    @Test("an empty day plans nothing at all")
    func empty() {
        let plan = MonthCellPlan(count: 0, height: 90, width: 150, rowHeight: 16)

        #expect(plan.chips == 0 && plan.dots == 0 && plan.overflow == 0)
        #expect(plan.isDotsOnly == false)
    }
}
