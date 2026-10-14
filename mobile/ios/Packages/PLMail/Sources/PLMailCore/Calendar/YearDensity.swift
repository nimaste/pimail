import Foundation

/// How busy each day of a year is, counted once for twelve month grids.
///
/// A year view draws 365 cells. Asking `DayGridLayout.place` per cell would
/// walk the whole cluster list 365 times — on a year with a daily standup in it
/// that is roughly half a million comparisons for a screen whose entire job is
/// to be tapped once. This walks the clusters **once** and buckets them by day
/// key instead.
///
/// **Counts, never colours.** A year cell is a few points across, so the only
/// thing it can carry is "something / a bit / a lot", and shading alone would
/// make the calendar's colour the sole carrier of meaning at the one size
/// where nobody can resolve it. Every cell states its count in its
/// accessibility label, and tapping through to the month is where the events
/// are actually named.
public struct YearDensity: Sendable {
    /// `yyyy-MM-dd` → how many clusters start on that day.
    ///
    /// **Starts, not spans.** A week-long conference would otherwise paint
    /// seven days as busy on the strength of one entry, which is exactly the
    /// impression a year view must not give — the question it answers is "which
    /// weeks did I have things on", not "which weeks was I away".
    private let counts: [String: Int]

    /// The busiest single day in the year, and the number every other day is
    /// shaded relative to.
    ///
    /// Relative rather than absolute, because a person with two events a week
    /// and a person with twelve both need the *shape* of their year and a fixed
    /// scale would render the first one uniformly blank.
    public let busiest: Int

    public init(clusters: [EventCluster]) {
        var counts: [String: Int] = [:]

        for cluster in clusters {
            counts[cluster.representative.start.calendarDay.key, default: 0] += 1
        }

        self.counts = counts
        busiest = counts.values.max() ?? 0
    }

    public func count(on day: CalendarDay) -> Int { counts[day.key] ?? 0 }

    /// `0…1`, for a fill's opacity. Zero for an empty day.
    ///
    /// Floored at a visible value once there is anything at all: a single event
    /// in a year of otherwise busy days would round to invisible, and a day
    /// that has something on it must never look like a day that has not.
    public func weight(on day: CalendarDay) -> Double {
        let count = count(on: day)

        guard count > 0, busiest > 0 else { return 0 }

        return max(0.25, Double(count) / Double(busiest))
    }
}
