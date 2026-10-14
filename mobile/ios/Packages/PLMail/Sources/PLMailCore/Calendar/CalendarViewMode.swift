import Foundation

/// What the calendar is showing, and therefore what window it asks for.
///
/// **The wire values are shared with the web UI and are persisted**, so they
/// cannot be renamed without stranding somebody's preference and without the
/// two surfaces disagreeing about what a week is called. A person who set their
/// view in a browser should find the same view here.
///
/// Four cases rather than Android's five. `month-agenda` is not a mode here: it
/// is what *month* looks like at a compact width, which is what iOS Calendar
/// does and what people already know. The wire value is still written and still
/// read, so neither surface can strand the other.
public enum CalendarViewMode: String, CaseIterable, Hashable, Sendable {
    /// A rolling 30-day list. The default, and the right default on a phone.
    case agenda
    case day
    case week
    case month
    /// Twelve month grids at once — **the one mode a large canvas is the whole
    /// point of**, and the one the web does not have.
    ///
    /// Its wire value is written like any other, and a browser reading it will
    /// not recognise it. That is deliberate and symmetric: this client already
    /// degrades a value it does not know to its own default, so the web doing
    /// the same costs a user who set Year here one view mode in a browser, and
    /// the alternative — writing `"month"` while showing a year — would be a
    /// preference that lies about what is on screen.
    case year

    /// The persisted spelling. See ``persistedWire(isCompactMonth:)`` for the
    /// one case where what is written differs from this.
    public var wire: String { rawValue }

    /// The wire value to persist.
    ///
    /// A compact month is drawn as a grid with the selected day expanded below
    /// it, which is exactly what the web calls `month-agenda` — so that is what
    /// is written, and a browser opened afterwards shows the same thing rather
    /// than a bare grid.
    public func persistedWire(isCompactMonth: Bool) -> String {
        self == .month && isCompactMonth ? "month-agenda" : rawValue
    }

    /// Degrades anything unknown to the default rather than failing.
    ///
    /// A preference written by a newer web release, or by a build that had five
    /// modes, must not leave the screen unable to open. `month-agenda` reads as
    /// month, because on this platform it is one.
    public static func fromWire(_ value: String?) -> CalendarViewMode {
        switch value {
        case "day": .day
        case "week": .week
        case "month", "month-full", "month-agenda": .month
        case "year": .year
        default: .agenda
        }
    }

    /// How many days the mode's window spans, before the anchor is applied.
    ///
    /// The month grid is **always six whole weeks**, never five-or-six, so
    /// paging through the year does not change the grid's height under the
    /// reader's finger. Its leading and trailing part-weeks are real days with
    /// real events, not padding.
    ///
    /// **Zero for year**, whose length is 365 or 366 and therefore cannot be a
    /// constant — a fixed 365 would drop 31 December out of every leap year's
    /// window, and nothing on the screen would say so. ``window(anchor:using:)``
    /// computes it instead.
    public var dayCount: Int {
        switch self {
        case .agenda: 30
        case .day: 1
        case .week: 7
        case .month: 42
        case .year: 0
        }
    }

    /// The window this mode shows around `anchor`.
    ///
    /// Every mode answers with one window because a visible span is one
    /// request. A week that fetched seven day-windows would be seven round
    /// trips for a screen that has not changed.
    public func window(
        anchor: CalendarDay, using calendar: Foundation.Calendar
    )
        -> CalendarWindow
    {
        // A year is bounded by month arithmetic rather than by a day count, so
        // a leap year is 366 days and an ordinary one 365 without either being
        // written down anywhere.
        if self == .year {
            let start = anchor.startOfYear

            return CalendarWindow(unchecked: start, to: start.adding(months: 12))
        }

        let start =
            switch self {
            case .agenda, .day: anchor
            case .week: anchor.startOfWeek(using: calendar)
            case .month, .year: anchor.startOfMonth.startOfWeek(using: calendar)
            }

        return CalendarWindow(unchecked: start, to: start.adding(days: dayCount))
    }

    /// Where `steps` presses of previous/next land.
    ///
    /// **Month steps by a month, not by its own 42 days** — stepping a six-week
    /// grid by its own length skips a fortnight every time — and month
    /// arithmetic lands correctly off the 31st. Agenda does not step at all: it
    /// is a rolling list rather than a page, so its buttons scroll rather than
    /// paginate.
    public func step(from anchor: CalendarDay, by steps: Int) -> CalendarDay {
        switch self {
        case .agenda: anchor
        case .day: anchor.adding(days: steps)
        case .week: anchor.adding(days: 7 * steps)
        case .month: anchor.adding(months: steps)
        // Twelve months rather than 365 days, for the same reason month steps
        // by a month: adding a fixed day count drifts a day every leap year,
        // so pressing Next four times would land in the wrong year.
        case .year: anchor.adding(months: 12 * steps)
        }
    }

    /// Whether previous/next mean anything here. Agenda's controls are hidden
    /// rather than disabled, since a rolling list has no next page to be at the
    /// end of.
    public var isPageable: Bool { self != .agenda }
}

// MARK: - Headings

/// What the toolbar says the visible period is.
///
/// Patterns come from the locale's own data through
/// `DateFormatter.dateFormat(fromTemplate:)` and are **never hand-written**: a
/// pattern that reads correctly in English and in German is neither the order
/// nor the wording several other locales use, and a calendar whose heading is
/// in the wrong order is wrong on every screen at once.
public enum CalendarHeading {
    /// A week's heading is a **range** whose near end drops what the far end
    /// repeats: the year when both share it, and the month too when the week
    /// does not cross one. That is the web toolbar's own rule, carried across so
    /// the two surfaces name the same week the same way.
    public static func text(
        mode: CalendarViewMode,
        anchor: CalendarDay,
        locale: Locale,
        calendar: Foundation.Calendar,
        timeZone: TimeZone
    ) -> String {
        switch mode {
        case .agenda, .day:
            return format(anchor, template: "yMMMd", locale: locale, timeZone: timeZone)
        case .month:
            return format(anchor, template: "yMMMM", locale: locale, timeZone: timeZone)
        case .year:
            return format(anchor, template: "y", locale: locale, timeZone: timeZone)
        case .week:
            let window = mode.window(anchor: anchor, using: calendar)
            let first = window.from
            let last = window.to.adding(days: -1)

            let nearTemplate =
                if first.year != last.year {
                    "yMMMd"
                } else if first.month != last.month {
                    "MMMd"
                } else {
                    "d"
                }

            return format(first, template: nearTemplate, locale: locale, timeZone: timeZone)
                + " – "
                + format(last, template: "yMMMd", locale: locale, timeZone: timeZone)
        }
    }

    /// A day's own label, for a section header or a grid column.
    public static func day(
        _ day: CalendarDay,
        template: String = "EEEd",
        locale: Locale,
        timeZone: TimeZone
    ) -> String {
        format(day, template: template, locale: locale, timeZone: timeZone)
    }

    /// Formats midday rather than midnight.
    ///
    /// Midnight does not exist on every day in every zone — a spring-forward
    /// transition at 00:00, which Santiago has — and a formatter handed a date
    /// that had to be rolled forward can print the next day. Midday exists
    /// everywhere and formats as the same date in every case.
    static func format(
        _ day: CalendarDay,
        template: String,
        locale: Locale,
        timeZone: TimeZone
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.calendar = CalendarDay.arithmetic(in: timeZone)
        formatter.dateFormat =
            DateFormatter.dateFormat(fromTemplate: template, options: 0, locale: locale)
            ?? template

        return formatter.string(from: day.middayInstant(in: timeZone))
    }
}
