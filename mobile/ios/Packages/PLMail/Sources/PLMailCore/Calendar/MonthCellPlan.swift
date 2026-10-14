import Foundation

/// How much of a day's events one month cell can actually carry.
///
/// **A function of measured size, never of idiom.** Android draws coloured dots
/// instead of titled chips because a 411 dp phone cell fits about four
/// characters — that is a phone compromise, and a 13-inch iPad cell is roughly
/// 150 × 110 pt, which carries three or four chips with titles and start times.
/// Branching on `UIDevice` would inherit the compromise on the device that does
/// not have the problem, and would get Slide Over, Stage Manager and a narrow
/// split view wrong in the other direction.
///
/// Pure, so the rule is testable without a simulator: the whole point is that
/// the same code answers differently for a 40 pt cell and a 110 pt one.
public struct MonthCellPlan: Hashable, Sendable {
    /// How many events get a titled chip.
    public let chips: Int
    /// How many are represented by a dot instead. Zero unless the cell is too
    /// small for a chip at all.
    public let dots: Int
    /// How many are not drawn individually and are summed into a "+n more"
    /// line. Never silently dropped: a day that shows two of six events and
    /// says nothing is a day the user believes has two.
    public let overflow: Int

    /// Whether this cell fell back to dots, which is the state that needs the
    /// count spoken aloud — a dot carries no title and no time.
    public var isDotsOnly: Bool { chips == 0 && dots > 0 }

    /// Whether a chip has room for its start time as well as its title.
    ///
    /// **A second measured threshold, not a second idiom check.** A 13-inch
    /// iPad month cell in landscape is ~145pt wide and carries "09:00 Standup"
    /// comfortably; the same cell in a 500pt Stage Manager window is ~70pt and
    /// would spend half of it on a time, leaving "Sta…". The title wins when
    /// only one of the two fits: the cell's position in the grid already says
    /// which day it is, and the title is the only thing that says what.
    public let showsStartTime: Bool

    /// Below this a chip is a time and three clipped characters.
    static let timeWidth: CGFloat = 110

    /// - Parameters:
    ///   - count: events on this day.
    ///   - height: the cell's usable height in points, after the date number.
    ///   - width: the cell's usable width in points.
    ///   - rowHeight: the height one chip needs at the current Dynamic Type
    ///     size. Passed in rather than assumed, because a chip at
    ///     `.accessibility3` is twice the height of one at `.medium` and a
    ///     hard-coded row count would clip it.
    public init(count: Int, height: CGFloat, width: CGFloat, rowHeight: CGFloat) {
        let showsStartTime = width >= Self.timeWidth

        guard count > 0 else {
            self = MonthCellPlan(
                chips: 0, dots: 0, overflow: 0, showsStartTime: showsStartTime)

            return
        }

        // A chip has to be wide enough for a couple of words plus a time before
        // it is worth drawing at all; narrower than this it is a coloured bar
        // with three clipped characters, which is a dot that costs more room.
        let minimumChipWidth: CGFloat = 56
        // Room for the "+n more" line, reserved only when it will be used.
        let overflowRowHeight = rowHeight * 0.8

        guard width >= minimumChipWidth, height >= rowHeight else {
            // Dots, in one row. Beyond what fits, the count carries the rest —
            // and the accessibility label says the number either way.
            let perDot: CGFloat = 12
            let fits = max(Int(width / perDot), 1)

            self = MonthCellPlan(
                chips: 0,
                dots: min(count, fits),
                overflow: max(count - min(count, fits), 0),
                showsStartTime: showsStartTime
            )

            return
        }

        let capacity = max(Int(height / rowHeight), 1)

        if count <= capacity {
            self = MonthCellPlan(
                chips: count, dots: 0, overflow: 0, showsStartTime: showsStartTime)

            return
        }

        // One row is given up to the overflow line, so "+2 more" never covers
        // an event it is not counting.
        let withOverflow = max(Int((height - overflowRowHeight) / rowHeight), 1)

        self = MonthCellPlan(
            chips: min(withOverflow, count),
            dots: 0,
            overflow: max(count - min(withOverflow, count), 0),
            showsStartTime: showsStartTime
        )
    }

    private init(chips: Int, dots: Int, overflow: Int, showsStartTime: Bool) {
        self.chips = chips
        self.dots = dots
        self.overflow = overflow
        self.showsStartTime = showsStartTime
    }
}
