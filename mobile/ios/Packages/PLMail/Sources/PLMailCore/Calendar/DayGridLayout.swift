import Foundation
public import JMAPKit

/// One cluster, placed in a day column.
///
/// **Positions are fractions of the column, not points**, so the same numbers
/// stay correct at whatever height the column ends up with — phone, tablet, a
/// zoomed grid, or an hour row grown by Dynamic Type — and nothing recomputes
/// when it changes.
public struct PlacedCluster: Hashable, Sendable, Identifiable {
    public let cluster: EventCluster
    /// `0` is the top of the column, `1` the bottom.
    public let top: Double
    /// A fraction of the column, never zero: a block with no height is a block
    /// nobody can tap.
    public let height: Double
    /// Which lane, from 0.
    public let lane: Int
    /// **The run's** lane count, not this block's own.
    ///
    /// Every span in a run gets the same number so block edges line up down the
    /// whole run. Sizing each pair independently produces a two-wide block
    /// beside a three-wide one, which reads as a rendering fault rather than as
    /// information.
    public let lanes: Int
    /// The event started before this day: draw a flush top edge and say so.
    public let continuesBefore: Bool
    /// The event runs past this day's end.
    public let continuesAfter: Bool

    public var id: CalendarEventID { cluster.id }
}

/// Everything a day column draws.
public struct DayGrid: Hashable, Sendable {
    public let date: CalendarDay
    /// All-day and multi-day clusters. They never enter the lane algorithm;
    /// they go to a band above the axis, where a 24-hour block would otherwise
    /// fill the column and hide every timed event behind it.
    public let allDay: [EventCluster]
    public let timed: [PlacedCluster]

    public var isEmpty: Bool { allDay.isEmpty && timed.isEmpty }
}

/// Where blocks go in a day column — a rule-for-rule port of the web's
/// `App\Service\Calendar\DayGridLayout`.
///
/// Pure, and deliberately free of SwiftUI: the whole of the interesting
/// behaviour here is arithmetic, and arithmetic tested through a rendered view
/// is arithmetic that is not tested.
public enum DayGridLayout {
    /// Minutes in the drawn day. **Always 1440**, even on the two days a year
    /// that are not 24 hours long.
    ///
    /// The grid draws 24 labelled rows and a block lands against the row whose
    /// label matches the clock the reader sees. The consequences are stated
    /// rather than hidden: on a spring-forward day the 02:00 row is drawn
    /// although nothing can be in it, and on a fall-back day the two 02:00s
    /// draw over each other as an overlap. Both are what every other calendar
    /// does, and both are preferable to blocks that do not line up with the
    /// labels beside them.
    public static let minutesInDay = 1440

    /// The granularity tap-to-create snaps to.
    public static let slotMinutes = 15

    /// A span clipped to one day, in wall-clock minutes from its midnight.
    struct Span: Hashable, Sendable {
        let cluster: EventCluster
        let from: Int
        let to: Int
        let continuesBefore: Bool
        let continuesAfter: Bool
    }

    // MARK: - Placement

    public static func place(_ clusters: [EventCluster], on date: CalendarDay) -> DayGrid {
        var allDay: [EventCluster] = []
        var spans: [Span] = []

        for cluster in clusters {
            let row = cluster.representative

            // **All-day only** goes to the band. A *timed* event that happens
            // to cross midnight — a flight, a night shift — is clipped into
            // each day's column instead and flagged as continuing, because its
            // hours are the thing worth reading and the band has no axis to
            // read them against.
            if row.isAllDay {
                if spansDay(row, date) { allDay.append(cluster) }
                continue
            }

            if let span = spanOf(cluster, on: date) { spans.append(span) }
        }

        return DayGrid(date: date, allDay: allDay, timed: assignLanes(spans))
    }

    /// Whether an all-day or multi-day row touches this date at all.
    ///
    /// The end is exclusive on a midnight boundary for the same reason
    /// ``spanOf(_:on:)``'s `>=` is: a stay ending at midnight on Friday ended on
    /// Thursday, and drawing it on Friday adds a day to every hotel booking.
    static func spansDay(_ row: EventRow, _ date: CalendarDay) -> Bool {
        let start = row.start.calendarDay
        let endDay = row.end.calendarDay
        let endsAtMidnight = row.end.minuteOfDay == 0 && (row.end.components.second ?? 0) == 0
        let last = endsAtMidnight && endDay > start ? endDay.adding(days: -1) : endDay

        return date >= start && date <= last
    }

    /// Clips one cluster to `date`.
    ///
    /// The `>=`/`>` asymmetry on the end is the bug this function exists for:
    /// an event finishing **exactly** at midnight is not continuing into
    /// tomorrow, but its end reads as 00:00, which as a height would run from
    /// its start back up to the top of the column. So the height is filled to
    /// the bottom and the flag is left off.
    static func spanOf(_ cluster: EventCluster, on date: CalendarDay) -> Span? {
        let row = cluster.representative
        let dayStart = LocalDateTime.midnight(of: date)
        // The next day's midnight, calendrically — **not** plus 1440 minutes,
        // which is an hour out on a DST day.
        let dayEnd = LocalDateTime.midnight(of: date.adding(days: 1))

        guard row.start < dayEnd, row.end > dayStart || row.start >= dayStart else { return nil }

        let startsBefore = row.start < dayStart
        let from = startsBefore ? 0 : row.start.minuteOfDay
        var to = row.end >= dayEnd ? minutesInDay : row.end.minuteOfDay

        // An end before its start is data to survive, not geometry to compute
        // from: a corrupt duration must draw a zero-height block on the right
        // day rather than an inverted one covering the morning.
        to = max(from, to)

        return Span(
            cluster: cluster,
            from: from,
            to: to,
            continuesBefore: startsBefore,
            continuesAfter: row.end > dayEnd
        )
    }

    // MARK: - Lanes

    /// Overlap answered by lanes, **in runs**.
    ///
    /// 1. Sort by `from` ascending, then by `to` **descending** — longest-first
    ///    among equal starts, so the block that covers the others takes lane 0
    ///    and the short ones stack to its right. The reverse puts the long block
    ///    in the rightmost lane with a column of stubs beside it that look like
    ///    the main event.
    /// 2. Accumulate a **run**: spans join while `span.from < runEnd`, where
    ///    `runEnd` is the running maximum of `to`. The first span starting at or
    ///    after `runEnd` closes the run.
    /// 3. Within a run, greedy first-fit. Greedy is optimal for interval
    ///    colouring on a start-sorted list, which is why the sort is not
    ///    incidental.
    /// 4. Every span in a run gets the run's total lane count.
    ///
    /// **Deliberately not done:** an event with free lanes to its right is not
    /// widened to fill them. It looks tidier and it makes a block's width depend
    /// on events it does not overlap — so adding an event at 3pm would resize
    /// one at 9am, and the width would stop being readable as "this many things
    /// are happening at once", which is the only thing the width is for.
    static func assignLanes(_ spans: [Span]) -> [PlacedCluster] {
        let sorted = spans.sorted { left, right in
            if left.from != right.from { return left.from < right.from }
            if left.to != right.to { return left.to > right.to }

            return EventClusterer.precedes(
                left.cluster.representative, right.cluster.representative)
        }

        var placed: [PlacedCluster] = []
        var run: [Span] = []
        var runLanes: [Int] = []
        var laneEnds: [Int] = []
        var runEnd = Int.min

        func closeRun() {
            let lanes = max(laneEnds.count, 1)

            for (span, lane) in zip(run, runLanes) {
                placed.append(make(span, lane: lane, lanes: lanes))
            }

            run = []
            runLanes = []
            laneEnds = []
            runEnd = Int.min
        }

        for span in sorted {
            if run.isEmpty == false && span.from >= runEnd { closeRun() }

            let lane: Int

            if let free = laneEnds.firstIndex(where: { $0 <= span.from }) {
                laneEnds[free] = span.to
                lane = free
            } else {
                laneEnds.append(span.to)
                lane = laneEnds.count - 1
            }

            run.append(span)
            runLanes.append(lane)
            runEnd = max(runEnd, span.to)
        }

        if run.isEmpty == false { closeRun() }

        return placed
    }

    private static func make(_ span: Span, lane: Int, lanes: Int) -> PlacedCluster {
        let total = Double(minutesInDay)
        let top = Double(span.from) / total
        // A floor of one minute: a zero-length event is legal on the wire and a
        // block with no height cannot be tapped, read, or focused by VoiceOver.
        let height = max(Double(span.to - span.from), 1) / total

        return PlacedCluster(
            cluster: span.cluster,
            top: top,
            height: min(height, 1 - top),
            lane: lane,
            lanes: lanes,
            continuesBefore: span.continuesBefore,
            continuesAfter: span.continuesAfter
        )
    }

    // MARK: - Tap to create

    /// A fraction down the column to the minute a new event should start.
    ///
    /// Snapped **down** to the quarter hour rather than to the nearest: a tap
    /// just above the 10:00 line meaning *ten* is the same gesture as a tap just
    /// below it, and rounding up would put an event at a time above where the
    /// finger was. Clamped rather than trusted, or a fling a pixel past the
    /// bottom proposes 24:00 — a time that is not on the day it was tapped.
    public static func slotAt(fraction: Double) -> Int {
        let raw = Int((fraction * Double(minutesInDay)).rounded(.down))
        let clamped = min(max(raw, 0), minutesInDay - 1)

        return (clamped / slotMinutes) * slotMinutes
    }

    /// The wall clock a tap at `fraction` proposes.
    public static func slotStart(on date: CalendarDay, fraction: Double) -> LocalDateTime {
        let minutes = slotAt(fraction: fraction)

        return LocalDateTime(
            year: date.year,
            month: date.month,
            day: date.day,
            hour: minutes / 60,
            minute: minutes % 60,
            second: 0
        )
    }
}
