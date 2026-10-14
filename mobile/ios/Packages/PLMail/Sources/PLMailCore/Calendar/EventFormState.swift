import Foundation
public import JMAPKit

/// A time of day, with no date and no zone.
///
/// Separate from ``CalendarDay`` for the reason the editor has two controls
/// rather than one: the all-day toggle uses only half of each, so a joined
/// `LocalDateTime` would have to invent a time and then remember to ignore it —
/// and the invented time is what reappears the moment somebody turns the toggle
/// back off.
public struct WallClockTime: Hashable, Sendable, Comparable {
    public var hour: Int
    public var minute: Int

    /// What an all-day event's start is written as. Never drawn: the editor
    /// does not render a time control for an all-day event at all, because a
    /// disabled control still invites a press and still reads out to VoiceOver.
    public static let midnight = WallClockTime(hour: 0, minute: 0)

    public init(hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }

    /// Minutes since midnight, `0..<1440` for any legal value.
    public var minuteOfDay: Int { hour * 60 + minute }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.minuteOfDay < rhs.minuteOfDay
    }
}

/// The five repeat choices this product writes, on either surface.
///
/// **Not a recurrence editor.** Anything more elaborate — every second Tuesday,
/// weekdays only — arrives from an invitation, an import or a mirrored calendar
/// and is carried faithfully, never composed here. That is also why this is
/// offered on **create only**: the cache stores *whether* a series recurs and
/// never the rule it recurs by, so a value picked from this list and sent as an
/// update would flatten an imported rule to "every week" because somebody
/// corrected a typo — or clear it outright, since null on that property means
/// *stop recurring*.
public enum EventRepeat: String, Hashable, Sendable, CaseIterable, Identifiable {
    case never
    case daily
    case weekly
    case monthly
    case yearly

    public var id: String { rawValue }

    /// The JSCalendar `frequency`, or nil for a one-off.
    public var frequency: String? {
        switch self {
        case .never: nil
        default: rawValue
        }
    }

    /// The rule to send on a **create**, or nil when the event does not repeat.
    ///
    /// Nil rather than a rule with a nil frequency: the server reads a rule
    /// object with no frequency as `invalidProperties`, and an event that does
    /// not repeat has no rule at all rather than an empty one.
    public var rule: RecurrenceRule? {
        frequency.map { RecurrenceRule(frequency: $0) }
    }
}

/// Why a form cannot be saved yet.
///
/// A closed set rather than a `Bool`, because the two ordering rules produce
/// **different sentences** and showing the wrong one is worse than showing
/// none: telling somebody an all-day event "must end after it starts" when it
/// starts and ends on the same day describes a rule that does not exist.
public enum EventFormProblem: Hashable, Sendable {
    /// All-day: the end date is earlier than the start date. Same day is one
    /// day and perfectly ordinary.
    case endsBeforeStart

    /// Timed: the end is not strictly later than the start. A zero-length timed
    /// event is refused, matching the server and the web.
    case doesNotEndAfterStart

    /// No calendar chosen, or none that accepts new items. `myRights` is the
    /// only authority here — a calendar that mirrors somewhere read-only
    /// answers `forbidden` after the user has typed the whole event.
    case noCalendar
}

/// Everything the editor holds, and the two validation rules, as a value.
///
/// Pure and free of SwiftUI so the rules can be tested as functions. The rules
/// are the reason this type exists: **"after" means something different on each
/// side of the all-day toggle**, and comparing the two midnights of a one-day
/// all-day event would refuse the commonest all-day event there is.
public struct EventFormState: Hashable, Sendable {
    public var title: String = ""

    /// **Setting this shifts the end by the same number of days.**
    ///
    /// Moving a meeting from Tuesday to Thursday means moving the whole
    /// meeting; a start picker that left the end where it was would silently
    /// turn a one-hour meeting into a negative one and then refuse to save,
    /// with nothing on screen saying which field the user was supposed to
    /// correct.
    public var startDate: CalendarDay {
        get { storedStartDate }
        set {
            let shift = storedStartDate.days(until: newValue)
            storedStartDate = newValue
            storedEndDate = storedEndDate.adding(days: shift)
        }
    }

    /// **Moves only the end.** The end picker is how a user changes the length
    /// of something, so shifting anything else from here would undo the edit
    /// they just made.
    public var endDate: CalendarDay {
        get { storedEndDate }
        set { storedEndDate = newValue }
    }

    /// Not drawn at all when ``isAllDay``. Kept across the toggle so that
    /// turning all-day on and off again restores the times the user chose,
    /// rather than proposing 00:00 for a meeting.
    public var startTime: WallClockTime
    public var endTime: WallClockTime

    public var isAllDay: Bool

    /// One calendar, not a set of ticks: a JMAP event lives on exactly one
    /// calendar and `calendarId` is a single value, so a multi-select would be
    /// offering something the wire cannot express.
    public var calendarID: CalendarID?

    /// Offered on create and read-only on edit. See ``EventRepeat``.
    public var repeatRule: EventRepeat = .never

    public var location: String = ""
    public var notes: String = ""

    /// The series being edited, or nil on a create. **A series id, never an
    /// occurrence id** — `CalendarEvent/set` refuses the latter by name.
    public let editing: CalendarEventID?

    /// Whether the event being edited already repeats. Drives the read-only
    /// recurrence line; false on a create.
    public let isRecurringSeries: Bool

    private var storedStartDate: CalendarDay
    private var storedEndDate: CalendarDay

    // MARK: - Creating

    /// A new event starting at `start` and lasting an hour.
    ///
    /// The caller decides `start`, because the two ways of opening the editor
    /// want different answers: the **+** button proposes the next whole hour
    /// (see ``nextWholeHour(after:in:)``), and a tap on a grid slot uses the
    /// slot **unrounded** — the slot is already snapped to the quarter hour,
    /// and rounding again would move a tap on the 14:15 line to 15:00, which is
    /// the one thing the gesture promises not to do.
    public init(creatingAt start: LocalDateTime, calendarID: CalendarID?, isAllDay: Bool = false) {
        let day = start.calendarDay
        storedStartDate = day
        storedEndDate = day
        startTime = WallClockTime(
            hour: start.components.hour ?? 0, minute: start.components.minute ?? 0)

        // One hour later, rolling the date when the start is in the last hour
        // of the day — an event created at 23:30 ends at 00:30 tomorrow, not at
        // 00:30 the same morning.
        let end = start.adding(.hour)
        storedEndDate = end.calendarDay
        endTime = WallClockTime(
            hour: end.components.hour ?? 0, minute: end.components.minute ?? 0)

        self.isAllDay = isAllDay
        self.calendarID = calendarID
        editing = nil
        isRecurringSeries = false
    }

    /// The next whole hour after `now`, in `zone`.
    ///
    /// An editor opened at 14:07 that proposes 14:07 asks the user to correct a
    /// time nobody would ever choose.
    public static func nextWholeHour(after now: Date, in zone: TimeZone) -> LocalDateTime {
        let clock = LocalDateTime(now, in: zone)
        let day = clock.calendarDay
        let hour = (clock.components.hour ?? 0) + 1

        // 23:xx rolls into tomorrow rather than producing hour 24, which is not
        // a wall clock any parser accepts.
        if hour > 23 {
            let tomorrow = day.adding(days: 1)

            return LocalDateTime(
                year: tomorrow.year, month: tomorrow.month, day: tomorrow.day,
                hour: 0, minute: 0, second: 0)
        }

        return LocalDateTime(
            year: day.year, month: day.month, day: day.day,
            hour: hour, minute: 0, second: 0)
    }

    // MARK: - Editing

    /// Seeded from the **series**, never from the tapped occurrence.
    ///
    /// An update sends whole properties, so a form filled in from one
    /// occurrence of a weekly standup would send that Tuesday as the series'
    /// start — and saving a corrected spelling would drag every other
    /// occurrence onto the week the user happened to be looking at.
    ///
    /// **An all-day event's end date is drawn a day earlier than it is
    /// stored.** The duration counts whole days from midnight, so the stored
    /// end lands on the midnight *after* the last day covered; drawing that
    /// date would tell the user a one-day event lasts two.
    public init(editing series: CalendarEventSnapshot) {
        let start =
            LocalDateTime(rawValue: series.startLocal)
            ?? LocalDateTime(year: 1970, month: 1, day: 1, hour: 0, minute: 0, second: 0)
        let allDay = series.showWithoutTime
        let end = start.end(after: series.duration, isAllDay: allDay)

        storedStartDate = start.calendarDay
        startTime = WallClockTime(
            hour: start.components.hour ?? 0, minute: start.components.minute ?? 0)

        if allDay {
            // Clamped at the start day so a stored `PT0S` on an all-day event —
            // which the server should never emit but an import can — draws as
            // one day rather than as ending the day before it begins.
            let drawn = end.calendarDay.adding(days: -1)
            storedEndDate = max(drawn, start.calendarDay)
            endTime = .midnight
        } else {
            storedEndDate = end.calendarDay
            endTime = WallClockTime(
                hour: end.components.hour ?? 0, minute: end.components.minute ?? 0)
        }

        title = series.title
        isAllDay = allDay
        calendarID = series.calendarID
        location = series.locationName ?? ""
        notes = series.eventDescription ?? ""
        editing = series.eventID
        isRecurringSeries = series.isRecurring
        repeatRule = .never
    }

    // MARK: - The rules

    /// Why this cannot be saved, or nil when it can.
    public var problem: EventFormProblem? {
        guard calendarID != nil else { return .noCalendar }

        if isAllDay {
            // **Same day is one day**, and that is the commonest all-day event
            // there is.
            return endDate < startDate ? .endsBeforeStart : nil
        }

        return endsAfterStart ? nil : .doesNotEndAfterStart
    }

    public var isValid: Bool { problem == nil }

    /// Strictly later, which is what "a timed event must end after it starts"
    /// means. Equal is a zero-length event, and the server refuses it too.
    private var endsAfterStart: Bool {
        if endDate != startDate { return startDate < endDate }

        return startTime < endTime
    }

    /// Whether the recurrence control is offered at all.
    ///
    /// Create only. On an edit the field states what will happen instead, which
    /// is that the rule is left exactly as it is.
    public var mayEditRecurrence: Bool { editing == nil }

    // MARK: - What gets sent

    /// The start, as the wire spells it. Midnight for an all-day event: the
    /// time controls are not drawn, so any other value would be a decision the
    /// user never made.
    public var start: LocalDateTime {
        LocalDateTime(
            year: startDate.year, month: startDate.month, day: startDate.day,
            hour: isAllDay ? 0 : startTime.hour,
            minute: isAllDay ? 0 : startTime.minute,
            second: 0
        )
    }

    /// How long the event lasts, in **whole date parts plus a clock part**.
    ///
    /// All-day is `daysBetween + 1`, both ends included — the stored duration
    /// counts whole days from midnight, which is the inverse of the day the
    /// editor draws.
    ///
    /// A timed event spanning midnight is `P1DT12H` rather than `PT36H`: the
    /// user picked a date and a time, and the two differ by an hour on the days
    /// that are not 24 hours long.
    public var duration: EventDuration {
        if isAllDay {
            return EventDuration(days: max(1, startDate.days(until: endDate) + 1))
        }

        var days = startDate.days(until: endDate)
        var minutes = endTime.minuteOfDay - startTime.minuteOfDay

        if minutes < 0 {
            minutes += 24 * 60
            days -= 1
        }

        return EventDuration(days: max(0, days), hours: minutes / 60, minutes: minutes % 60)
    }

    /// The title actually sent.
    ///
    /// **An empty title becomes the localised word, not a refusal.** JMAP
    /// refuses an empty title outright and plMail's web editor stores the word,
    /// so matching it means an event created on a phone and one created in a
    /// browser are the same event. The word is passed in because this type has
    /// no bundle and translating from a model layer is how a German user ends
    /// up with an English event.
    public func resolvedTitle(untitled: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)

        return trimmed.isEmpty ? untitled : trimmed
    }

    /// What to send, or nil when ``problem`` says there is nothing to send.
    public func draft(untitled: String) -> EventDraft? {
        guard let calendarID, isValid else { return nil }

        let trimmedLocation = location.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)

        return EventDraft(
            calendarID: calendarID,
            title: resolvedTitle(untitled: untitled),
            start: start,
            duration: duration,
            isAllDay: isAllDay,
            location: trimmedLocation.isEmpty ? nil : trimmedLocation,
            notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
            // **Create only**, and the type carries it rather than the caller
            // remembering to: an update built from this dropdown would flatten
            // an imported rule.
            recurrence: mayEditRecurrence ? repeatRule : .never
        )
    }
}

// MARK: - Binding a wall clock to a `Date`

/// Turns the editor's zone-free values into the `Date` a `DatePicker` binds to,
/// and back.
///
/// **The zone is a parameter and both directions use the same one**, which is
/// the whole point: a day built in one zone and read back in another is the day
/// before or after for everybody whose offset crosses midnight, and the bug
/// shows up only for users east or west of whoever wrote the code. The editor
/// passes the environment's own `timeZone`, so the value the picker renders and
/// the value read back out of it are the same wall clock by construction.
///
/// Nothing here converts a time. A `Date` is used purely because `DatePicker`
/// has no other currency; the event's own clock is never moved into the
/// device's zone.
public enum WallClockDate {
    /// The instant `zone` shows this wall clock at.
    ///
    /// Falls back to the day's first existing instant plus the clock offset
    /// when the wall clock does not exist — 00:00 does not exist in Santiago on
    /// a spring-forward day, and a picker that could not represent a date would
    /// drop the control rather than the hour.
    public static func date(day: CalendarDay, time: WallClockTime, in zone: TimeZone) -> Date {
        var components = day.dateComponents
        components.hour = time.hour
        components.minute = time.minute

        if let exact = CalendarDay.arithmetic(in: zone).date(from: components) { return exact }

        return day.startOfDay(in: zone).addingTimeInterval(TimeInterval(time.minuteOfDay * 60))
    }

    /// The day `date` falls on in `zone` — the exact inverse of
    /// ``date(day:time:in:)`` for every zone, which is what keeps a picker from
    /// moving an event a day when the user has not touched it.
    public static func day(of date: Date, in zone: TimeZone) -> CalendarDay {
        CalendarDay(date, in: zone)
    }

    /// The wall clock `date` shows in `zone`.
    public static func time(of date: Date, in zone: TimeZone) -> WallClockTime {
        let parts = CalendarDay.arithmetic(in: zone)
            .dateComponents([.hour, .minute], from: date)

        return WallClockTime(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
    }
}
