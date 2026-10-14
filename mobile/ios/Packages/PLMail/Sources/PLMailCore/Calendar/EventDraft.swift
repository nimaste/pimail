import Foundation
public import JMAPKit

/// One whole event, as the editor means it — the value that becomes either a
/// create or a patch.
///
/// Between ``EventFormState`` and the wire on purpose. The form knows about
/// pickers and toggles; the wire types know about `invalidProperties`; this
/// knows which of the **thirteen writable properties** each field is, and it is
/// the only place that decision is made.
///
/// **There is no zone here, and that is the design.** The editor offers no
/// timezone control, so every write omits `timeZone` and takes the calendar's
/// own — sending the *device's* zone would record a decision the user never
/// made, and would make the same event read differently on the two surfaces the
/// first time somebody travels. ``JMAPKit/EventTimeZone`` exists and models all
/// three states; the editor simply does not expose it.
///
/// `participants`, `alerts`, `links` and `privacy` are not here because they
/// are not writable, and ``JMAPKit/NewCalendarEvent`` and
/// ``JMAPKit/CalendarEventPatch`` have no way to name them at all — so this
/// cannot send one by accident.
public struct EventDraft: Hashable, Sendable {
    public var calendarID: CalendarID
    /// Never empty. ``EventFormState/resolvedTitle(untitled:)`` substitutes the
    /// localised word, because the server refuses `""` outright.
    public var title: String
    public var start: LocalDateTime
    public var duration: EventDuration
    public var isAllDay: Bool
    /// A plain label. plMail stores one place and stores it as a name, so there
    /// is nothing to geocode and a second entry is `invalidProperties`.
    public var location: String?
    public var notes: String?

    /// **Applied on create only.** ``patch(clearingLocation:)`` never names
    /// `recurrenceRules`, whatever this holds.
    public var recurrence: EventRepeat

    public init(
        calendarID: CalendarID,
        title: String,
        start: LocalDateTime,
        duration: EventDuration,
        isAllDay: Bool = false,
        location: String? = nil,
        notes: String? = nil,
        recurrence: EventRepeat = .never
    ) {
        self.calendarID = calendarID
        self.title = title
        self.start = start
        self.duration = duration
        self.isAllDay = isAllDay
        self.location = location
        self.notes = notes
        self.recurrence = recurrence
    }

    /// Where the event ends, in wall-clock terms. What the optimistic cache
    /// edit draws with, and never a `Date` arithmetic on the start.
    public var end: LocalDateTime { start.adding(duration) }

    /// The create body.
    ///
    /// `uid` is left nil so the server mints a stable `<hex>@plmail`. Supplying
    /// one is only correct when re-creating an event that came from elsewhere
    /// and has to keep its identity across servers, which this editor never
    /// does.
    public func newEvent() -> NewCalendarEvent {
        NewCalendarEvent(
            calendarID: calendarID,
            title: title,
            start: start,
            duration: duration.wireValue,
            eventDescription: notes,
            // Omitted, which is "the calendar's own zone". See the type note.
            timeZone: nil,
            showWithoutTime: isAllDay,
            location: location,
            status: .confirmed,
            recurrenceRule: recurrence.rule
        )
    }

    /// The update patch.
    ///
    /// Every field the editor owns is named, whether or not it changed. A diff
    /// would have to be right about what the cache holds, and the cache's
    /// columns are a lossy projection of the canonical body by construction —
    /// so a field the projection had dropped would look unchanged and would
    /// never be corrected. Naming them all costs nothing: an update is a patch
    /// layered over the stored event, and a property set to what it already was
    /// is a no-op server-side.
    ///
    /// **`recurrenceRules` is never named**, and neither is `uid` (which is
    /// `invalidProperties` in an update, the uid being the event's identity)
    /// nor `timeZone`, where an absent property already means "leave it alone".
    /// `recurrenceOverrides` is not named either: naming it **replaces the
    /// whole map**, so a patch that mentioned it would drop every exception on
    /// the series.
    public func patch() -> CalendarEventPatch {
        var patch = CalendarEventPatch()
        patch.setCalendarID(calendarID)
        patch.setTitle(title)
        patch.setStart(start)
        patch.setDuration(duration.wireValue)
        patch.setShowWithoutTime(isAllDay)
        patch.setLocation(location)
        patch.setDescription(notes)

        return patch
    }
}
