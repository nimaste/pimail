import Foundation
import JMAPKit
import Testing

@testable import PLMailCore

@Suite("Year view")
struct CalendarYearModeTests {
    private let gregorian = Foundation.Calendar(identifier: .gregorian)

    @Test("a year window is the whole year, and a leap year is a day longer")
    func length() {
        let ordinary = CalendarViewMode.year.window(
            anchor: CalendarDay(year: 2026, month: 7, day: 14), using: gregorian)
        let leap = CalendarViewMode.year.window(
            anchor: CalendarDay(year: 2028, month: 7, day: 14), using: gregorian)

        #expect(ordinary.from == CalendarDay(year: 2026, month: 1, day: 1))
        #expect(ordinary.to == CalendarDay(year: 2027, month: 1, day: 1))
        #expect(ordinary.dayCount == 365)
        #expect(leap.dayCount == 366)
    }

    @Test("a year window never exceeds the hard ceiling a window may ask for")
    func withinCeiling() {
        let leap = CalendarViewMode.year.window(
            anchor: CalendarDay(year: 2028, month: 2, day: 29), using: gregorian)

        #expect(leap.dayCount <= CalendarWindow.maxDays)
    }

    @Test("year steps by twelve months, so four presses land four years away")
    func steps() {
        var anchor = CalendarDay(year: 2026, month: 2, day: 29 - 1)

        for _ in 0..<4 { anchor = CalendarViewMode.year.step(from: anchor, by: 1) }

        #expect(anchor.year == 2030)
    }

    @Test("the year wire value round-trips, and an unknown one still degrades")
    func wire() {
        #expect(CalendarViewMode.fromWire("year") == .year)
        #expect(CalendarViewMode.year.persistedWire(isCompactMonth: false) == "year")
        #expect(CalendarViewMode.year.persistedWire(isCompactMonth: true) == "year")
        #expect(CalendarViewMode.fromWire("decade") == .agenda)
    }

    @Test("a year is pageable, because it has a next one")
    func pageable() {
        #expect(CalendarViewMode.year.isPageable)
    }
}

@Suite("Year density")
struct YearDensityTests {
    private func cluster(_ id: String, day: String, title: String = "Standup") -> EventCluster {
        CalendarFixture.cluster(
            id: id, start: "\(day)T09:00:00", end: "\(day)T09:15:00", title: title)
    }

    @Test("a day is counted by what starts on it, never by what spans it")
    func counts() {
        let density = YearDensity(clusters: [
            cluster("1", day: "2026-08-03"),
            cluster("2", day: "2026-08-03", title: "Retro"),
            cluster("3", day: "2026-08-05"),
        ])

        #expect(density.count(on: CalendarDay(year: 2026, month: 8, day: 3)) == 2)
        #expect(density.count(on: CalendarDay(year: 2026, month: 8, day: 5)) == 1)
        #expect(density.count(on: CalendarDay(year: 2026, month: 8, day: 4)) == 0)
        #expect(density.busiest == 2)
    }

    @Test("a day with anything on it is never shaded to invisible")
    func floor() {
        var clusters = [cluster("1", day: "2026-08-05")]

        for index in 0..<20 {
            clusters.append(cluster("x\(index)", day: "2026-08-03", title: "Meeting \(index)"))
        }

        let density = YearDensity(clusters: clusters)

        #expect(density.weight(on: CalendarDay(year: 2026, month: 8, day: 5)) >= 0.25)
        #expect(density.weight(on: CalendarDay(year: 2026, month: 8, day: 4)) == 0)
        #expect(density.weight(on: CalendarDay(year: 2026, month: 8, day: 3)) == 1)
    }

    @Test("an empty year has no busiest day and shades nothing")
    func empty() {
        let density = YearDensity(clusters: [])

        #expect(density.busiest == 0)
        #expect(density.weight(on: CalendarDay(year: 2026, month: 8, day: 3)) == 0)
    }
}

@Suite("Keyboard selection")
struct CalendarSelectionTests {
    private var clusters: [EventCluster] {
        (1...3).map {
            CalendarFixture.cluster(
                id: "\($0)", start: "2026-08-03T0\($0):00:00", end: "2026-08-03T0\($0):30:00",
                title: "Event \($0)")
        }
    }

    @Test("down moves to the next event and up moves back")
    func moves() {
        let second = CalendarSelection.step(
            from: CalendarEventID(rawValue: "1"), in: clusters, by: 1)
        let first = CalendarSelection.step(
            from: CalendarEventID(rawValue: "2"), in: clusters, by: -1)

        #expect(second?.representative.occurrenceID.rawValue == "2")
        #expect(first?.representative.occurrenceID.rawValue == "1")
    }

    @Test("the selection clamps at both ends rather than wrapping")
    func clamps() {
        let past = CalendarSelection.step(
            from: CalendarEventID(rawValue: "3"), in: clusters, by: 1)
        let before = CalendarSelection.step(
            from: CalendarEventID(rawValue: "1"), in: clusters, by: -1)

        #expect(past?.representative.occurrenceID.rawValue == "3")
        #expect(before?.representative.occurrenceID.rawValue == "1")
    }

    @Test("with nothing selected, down takes the first and up takes the last")
    func fromNothing() {
        #expect(
            CalendarSelection.step(from: nil, in: clusters, by: 1)?
                .representative.occurrenceID.rawValue == "1")
        #expect(
            CalendarSelection.step(from: nil, in: clusters, by: -1)?
                .representative.occurrenceID.rawValue == "3")
    }

    @Test("an arrow key over an empty period moves nothing rather than trapping")
    func emptyPeriod() {
        #expect(CalendarSelection.step(from: nil, in: [], by: 1) == nil)
    }

    @Test("a selection survives a re-query, and clears when the event is gone")
    func reselection() {
        let kept = CalendarSelection.reselect(CalendarEventID(rawValue: "2"), in: clusters)
        let gone = CalendarSelection.reselect(CalendarEventID(rawValue: "9"), in: clusters)

        #expect(kept?.representative.occurrenceID.rawValue == "2")
        #expect(gone == nil)
    }
}

@Suite("Local calendar search")
struct CalendarSearchTests {
    private let cluster = CalendarFixture.cluster(
        id: "1", start: "2026-08-03T09:00:00", end: "2026-08-03T09:15:00", title: "Bürodrucker")

    private func series(
        location: String? = nil, notes: String? = nil
    )
        -> CalendarEventSnapshot
    {
        var snapshot = CalendarEventSnapshot(
            accountKey: "a", eventID: CalendarEventID(rawValue: "1"), title: "Bürodrucker",
            startLocal: "2026-08-03T09:00:00")
        snapshot.locationName = location
        snapshot.eventDescription = notes

        return snapshot
    }

    @Test("an empty query keeps everything, because it is not a filter yet")
    func empty() {
        #expect(CalendarSearch.filter([cluster], query: "   ").count == 1)
    }

    @Test("case and diacritics fold, so burodrucker finds Bürodrucker")
    func folding() {
        #expect(CalendarSearch.matches(cluster, query: "burodrucker", series: nil))
        #expect(CalendarSearch.matches(cluster, query: "BÜRO", series: nil))
    }

    @Test("the calendar's own name narrows without a separate filter control")
    func calendarName() {
        #expect(CalendarSearch.matches(cluster, query: "work", series: nil))
    }

    @Test("the location and the notes are searched, and they live on the series")
    func seriesFields() {
        #expect(
            CalendarSearch.matches(cluster, query: "kitchen", series: series(location: "Kitchen")))
        #expect(
            CalendarSearch.matches(cluster, query: "toner", series: series(notes: "Bring toner")))
        // Without the series row the same query finds nothing rather than
        // crashing — a share offered before the series has loaded still works.
        #expect(CalendarSearch.matches(cluster, query: "toner", series: nil) == false)
    }

    @Test("a query nothing matches keeps the order of what is left, which is none")
    func noMatch() {
        #expect(CalendarSearch.filter([cluster], query: "zzz").isEmpty)
    }
}

@Suite("iCalendar export")
struct ICSExportTests {
    private func file(_ cluster: EventCluster, series: CalendarEventSnapshot? = nil) -> String {
        ICSExport.file(for: cluster, series: series, untitled: "Untitled")
    }

    @Test("a zoned event carries TZID and never a trailing Z")
    func zoned() {
        let text = file(
            CalendarFixture.cluster(
                id: "1", start: "2026-08-03T10:00:00", end: "2026-08-03T10:15:00"))

        #expect(text.contains("DTSTART;TZID=Europe/Berlin:20260803T100000"))
        #expect(text.contains("DTSTART:20260803T100000Z") == false)
    }

    @Test("a floating event carries neither a zone nor a Z, because it has neither")
    func floating() {
        let row = CalendarFixture.row(
            id: "1", start: "2026-08-03T10:00:00", end: "2026-08-03T10:15:00", zone: nil)
        let text = file(EventCluster(members: [row]))

        #expect(text.contains("DTSTART:20260803T100000"))
        #expect(text.contains("TZID") == false)
        #expect(text.contains("100000Z") == false)
    }

    @Test("an all-day event is a DATE value, not a midnight time")
    func allDay() {
        let text = file(
            CalendarFixture.cluster(
                id: "1", start: "2026-08-03T00:00:00", end: "2026-08-04T00:00:00",
                isAllDay: true))

        #expect(text.contains("DTSTART;VALUE=DATE:20260803"))
        #expect(text.contains("DTEND;VALUE=DATE:20260804"))
    }

    @Test("the uid is minted here, never the server's, so an import cannot claim the series")
    func freshUID() {
        let row = CalendarFixture.row(
            id: "10867_20260803", start: "2026-08-03T10:00:00", end: "2026-08-03T10:15:00",
            uid: "df7a@plmail")
        let text = file(EventCluster(members: [row]))

        #expect(text.contains("UID:10867_20260803@plmail.export"))
        #expect(text.contains("UID:df7a@plmail\r\n") == false)
    }

    @Test("a merged cluster exports one entry, not the duplicate it collapsed")
    func mergedExportsOnce() {
        let first = CalendarFixture.row(
            id: "1", start: "2026-08-03T10:00:00", end: "2026-08-03T10:15:00", calendar: "1")
        let second = CalendarFixture.row(
            id: "2", start: "2026-08-03T10:00:00", end: "2026-08-03T10:15:00", calendar: "2",
            calendarName: "Personal")
        let text = file(EventCluster(members: [first, second]))

        #expect(text.components(separatedBy: "BEGIN:VEVENT").count == 2)
    }

    @Test("the four reserved characters are escaped, and the backslash goes first")
    func escaping() {
        #expect(ICSExport.escape("a;b,c\\d") == "a\\;b\\,c\\\\d")
        #expect(ICSExport.escape("one\ntwo") == "one\\ntwo")
    }

    @Test("no recurrence rule is ever written, because the cache does not hold one")
    func noRule() {
        var series = CalendarEventSnapshot(
            accountKey: "a", eventID: CalendarEventID(rawValue: "1"), title: "Standup",
            startLocal: "2026-08-03T10:00:00")
        series.isRecurring = true

        let text = file(
            CalendarFixture.cluster(
                id: "1", start: "2026-08-03T10:00:00", end: "2026-08-03T10:15:00"),
            series: series)

        #expect(text.contains("RRULE") == false)
    }

    @Test("folding measures octets, so an umlaut is never cut in half")
    func folding() {
        let line = "DESCRIPTION:" + String(repeating: "ü", count: 80)
        let folded = ICSExport.fold(line)

        for piece in folded.components(separatedBy: "\r\n") {
            #expect(piece.utf8.count <= 75)
        }

        // Unfolding is dropping the CRLF and the one leading space each
        // continuation carries; what comes back must be what went in.
        #expect(folded.replacingOccurrences(of: "\r\n ", with: "") == line)
    }

    @Test("a short line is left exactly as it is")
    func noFolding() {
        #expect(ICSExport.fold("SUMMARY:Standup") == "SUMMARY:Standup")
    }

    @Test("a filename cannot carry a path separator out of the app")
    func filename() {
        let row = CalendarFixture.row(
            id: "1", start: "2026-08-03T10:00:00", end: "2026-08-03T10:15:00",
            title: "1:1 with Anna / Bob")
        let name = ICSExport.filename(for: EventCluster(members: [row]))

        #expect(name.contains("/") == false)
        #expect(name.hasSuffix(".ics"))
    }

    @Test("an untitled event uses the caller's word rather than an English literal")
    func untitled() {
        let row = CalendarFixture.row(
            id: "1", start: "2026-08-03T10:00:00", end: "2026-08-03T10:15:00", title: "")
        let text = ICSExport.file(
            for: EventCluster(members: [row]), series: nil, untitled: "Ohne Titel")

        #expect(text.contains("SUMMARY:Ohne Titel"))
    }
}

@Suite("What the calendar widget is given")
struct CalendarWidgetPlanTests {
    private let day = CalendarDay(year: 2026, month: 8, day: 3)

    private func cluster(
        _ id: String, from: String, to: String, allDay: Bool = false, at instant: Double
    ) -> EventCluster {
        EventCluster(members: [
            CalendarFixture.row(
                id: id, start: "2026-08-03T\(from):00", end: "2026-08-03T\(to):00",
                title: "Event \(id)", isAllDay: allDay,
                sortInstant: Date(timeIntervalSince1970: instant))
        ])
    }

    private func upcoming(_ clusters: [EventCluster], now: Double) -> [SharedCalendarEvent] {
        CalendarWidgetPlan.upcoming(
            in: clusters, today: day, now: Date(timeIntervalSince1970: now),
            timeText: { $0.representative.start.rawValue })
    }

    @Test("a meeting that has already started is still shown, because it is the one that matters")
    func inProgress() {
        let events = upcoming([cluster("1", from: "09:00", to: "10:00", at: 1000)], now: 2800)

        #expect(events.count == 1)
    }

    @Test("a meeting that has finished is dropped")
    func finished() {
        #expect(upcoming([cluster("1", from: "09:00", to: "10:00", at: 1000)], now: 5000).isEmpty)
    }

    @Test("all-day events come first, whatever instant they were projected onto")
    func allDayFirst() {
        let events = upcoming(
            [
                cluster("1", from: "09:00", to: "10:00", at: 5000),
                cluster("2", from: "00:00", to: "23:59", allDay: true, at: 9000),
            ], now: 0)

        #expect(events.first?.id == "2")
    }

    @Test("no more than the shared cap, so a busy day does not bloat what a widget reads")
    func cap() {
        let clusters = (1...9).map {
            cluster("\($0)", from: "09:00", to: "23:00", at: Double($0) * 100)
        }

        #expect(upcoming(clusters, now: 0).count == SharedCalendarState.limit)
    }

    @Test("a meeting crossing midnight has not finished before it began")
    func acrossMidnight() {
        let row = CalendarFixture.row(
            id: "1", start: "2026-08-03T23:30:00", end: "2026-08-04T00:30:00",
            sortInstant: Date(timeIntervalSince1970: 1000))

        #expect(row.endsAfter(Date(timeIntervalSince1970: 4000)))
        #expect(row.endsAfter(Date(timeIntervalSince1970: 5000)) == false)
    }

    @Test("the timeline is never empty, because an empty one is never asked about again")
    func timeline() {
        let now = Date(timeIntervalSince1970: 1000)
        let midnight = Date(timeIntervalSince1970: 9000)
        let points = CalendarWidgetPlan.refreshPoints(for: [], after: now, nextMidnight: midnight)

        #expect(points.isEmpty == false)
        #expect(points == points.sorted())
        #expect(points.last == midnight)
    }

    @Test("every event's end is a cut point, and ends already past are not")
    func cutPoints() {
        let now = Date(timeIntervalSince1970: 1000)
        let event = SharedCalendarEvent(
            id: "1", title: "Standup", timeText: "09:00",
            startsAt: now, endsAt: Date(timeIntervalSince1970: 4000))
        let stale = SharedCalendarEvent(
            id: "2", title: "Over", timeText: "08:00",
            startsAt: now, endsAt: Date(timeIntervalSince1970: 500))

        let points = CalendarWidgetPlan.refreshPoints(
            for: [event, stale], after: now, nextMidnight: Date(timeIntervalSince1970: 9000))

        #expect(points.contains(Date(timeIntervalSince1970: 4000)))
        #expect(points.contains(Date(timeIntervalSince1970: 500)) == false)
    }
}

@Suite("Event Spotlight index")
struct CalendarSpotlightPlanTests {
    private func row(
        _ id: String, title: String = "Standup", start: String = "2026-08-03T10:00:00",
        status: String? = "confirmed"
    ) -> CalendarOccurrenceSnapshot {
        var snapshot = CalendarOccurrenceSnapshot(
            accountKey: "nas.local/1",
            occurrenceID: CalendarEventID(rawValue: id),
            seriesID: CalendarEventID(rawValue: "10867"),
            recurrenceID: start,
            startLocal: start,
            startsAt: .distantPast,
            endsAt: .distantPast,
            title: title)
        snapshot.status = status

        return snapshot
    }

    @Test("an unchanged cache writes nothing, which is what stops this being a re-scan")
    func incremental() {
        let rows = [row("1"), row("2")]
        let record = Dictionary(
            uniqueKeysWithValues: rows.map {
                (CalendarSpotlightIndex.uid(for: $0), CalendarSpotlightIndex.signature(of: $0))
            })

        #expect(CalendarSpotlightIndex.pending(in: rows, alreadyIndexed: record).isEmpty)
    }

    @Test("a retitled or moved occurrence is re-indexed")
    func changed() {
        let before = row("1")
        let record = [
            CalendarSpotlightIndex.uid(for: before): CalendarSpotlightIndex.signature(of: before)
        ]

        #expect(
            CalendarSpotlightIndex.pending(
                in: [row("1", title: "Retro")], alreadyIndexed: record
            ).count == 1)
        #expect(
            CalendarSpotlightIndex.pending(
                in: [row("1", start: "2026-08-03T11:00:00")], alreadyIndexed: record
            ).count == 1)
    }

    @Test("a cancelled occurrence is re-indexed, because a stale entry sends somebody to it")
    func cancellation() {
        let before = row("1")
        let record = [
            CalendarSpotlightIndex.uid(for: before): CalendarSpotlightIndex.signature(of: before)
        ]

        #expect(
            CalendarSpotlightIndex.pending(
                in: [row("1", status: "cancelled")], alreadyIndexed: record
            ).count == 1)
    }

    @Test("an occurrence the cache no longer holds is taken back out of system search")
    func vanished() {
        let kept = row("1")
        let gone = row("2")
        let record = [
            CalendarSpotlightIndex.uid(for: kept): CalendarSpotlightIndex.signature(of: kept),
            CalendarSpotlightIndex.uid(for: gone): CalendarSpotlightIndex.signature(of: gone),
        ]

        #expect(
            CalendarSpotlightIndex.vanished(from: [kept], alreadyIndexed: record)
                == [CalendarSpotlightIndex.uid(for: gone)])
    }

    @Test("the identifier round-trips, splitting on the last hash rather than the first")
    func identifiers() {
        let uid = CalendarSpotlightIndex.uid(for: row("10867_20260803"))
        let ids = CalendarSpotlightIndex.ids(forUID: uid)

        #expect(ids?.accountKey == "nas.local/1")
        #expect(ids?.occurrenceID == "10867_20260803")
        #expect(CalendarSpotlightIndex.ids(forUID: "nothing") == nil)
        #expect(CalendarSpotlightIndex.ids(forUID: "#only") == nil)
    }
}

@Suite("A month cell on the canvas it is actually drawn on")
struct MonthCellGeometryTests {
    /// A 13-inch iPad in landscape: 1032pt of usable grid width across seven
    /// columns, and roughly 660pt of height across six rows, at default
    /// Dynamic Type.
    @Test("a 13-inch iPad month cell draws titled chips, not dots")
    func thirteenInch() {
        let plan = MonthCellPlan(
            count: 3, height: 110 - 16 - 6, width: 1032 / 7 - 4, rowHeight: 16)

        #expect(plan.chips == 3)
        #expect(plan.isDotsOnly == false)
    }

    @Test("an iPhone month cell falls back to dots, and for a measured reason")
    func phone() {
        // 390pt across seven columns is a 51pt cell — below the 56pt a chip
        // needs before it is a coloured bar with three clipped characters.
        let plan = MonthCellPlan(count: 3, height: 60, width: 390 / 7 - 4, rowHeight: 16)

        #expect(plan.isDotsOnly)
    }

    @Test("a wide cell carries the start time as well, and a narrow one does not")
    func startTimes() {
        // 13-inch landscape: 1376pt of window, ~1030pt of grid across seven.
        let wide = MonthCellPlan(count: 3, height: 90, width: 1030 / 7 - 4, rowHeight: 16)
        // The same grid in a 500pt Stage Manager window.
        let narrow = MonthCellPlan(count: 3, height: 90, width: 480 / 7 - 4, rowHeight: 16)

        #expect(wide.showsStartTime)
        #expect(narrow.showsStartTime == false)
    }

    @Test("an empty cell still answers the width question, so nothing has to guess")
    func emptyCellStillMeasures() {
        #expect(MonthCellPlan(count: 0, height: 90, width: 150, rowHeight: 16).showsStartTime)
    }

    @Test("a 13-inch cell at an accessibility text size gives up chips on its own")
    func largeText() {
        let plan = MonthCellPlan(
            count: 3, height: 110 - 44 - 6, width: 1032 / 7 - 4, rowHeight: 44)

        #expect(plan.chips == 1)
        #expect(plan.overflow == 2)
    }
}
