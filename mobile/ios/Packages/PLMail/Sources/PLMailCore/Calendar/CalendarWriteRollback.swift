import Foundation
public import JMAPKit

/// Everything an optimistic write overwrote, in full, so it can be put back
/// exactly.
///
/// **Column-for-column rather than snapshot-shaped.** `CalendarEventSnapshot`
/// is what the UI reads and it deliberately drops fields no view uses —
/// `createdAt`, `updatedAt`, the day key — so restoring from one would leave
/// the cache *nearly* as it was, and "nearly" is the state that survives to the
/// next refresh looking like a server change nobody made.
///
/// Held by value and `Sendable` because the write crosses the store actor twice
/// with a network round trip in between, and a `@Model` object may not make
/// that journey.
public struct CalendarWriteRollback: Hashable, Sendable {
    /// One series row, every column.
    struct SeriesRecord: Hashable, Sendable {
        var uid: String
        var accountKey: String
        var eventID: String
        var calendarID: String?
        var wireUID: String?
        var title: String
        var startLocal: String
        var duration: String?
        var timeZoneName: String?
        var hasExplicitTimeZone: Bool
        var showWithoutTime: Bool
        var eventDescription: String?
        var locationName: String?
        var status: String?
        var privacy: String?
        var isRecurring: Bool
        var kind: String?
        var source: String?
        var sequence: Int
        var createdAt: Date?
        var updatedAt: Date?
        var jsCalendarJSON: Data?
    }

    /// One occurrence row, every column.
    struct OccurrenceRecord: Hashable, Sendable {
        var uid: String
        var accountKey: String
        var occurrenceID: String
        var seriesID: String
        var calendarID: String?
        var recurrenceID: String
        var recurrenceIDTimeZone: String?
        var startLocal: String
        var duration: String?
        var startsAt: Date
        var endsAt: Date
        var dayKey: String
        var isAllDay: Bool
        var title: String
        var status: String?
    }

    let accountKey: String
    let seriesID: CalendarEventID

    /// Nil when the series was not cached at all, which is legal: an editor can
    /// be opened on a window that has since been swept. Restoring then means
    /// leaving it absent, not inventing a row.
    var series: SeriesRecord?

    /// Every occurrence of the series **anywhere in the cache**, not only in
    /// the visible window — a delete drops them all, so putting them back has
    /// to as well.
    var occurrences: [OccurrenceRecord]
}

extension CalendarWriteRollback.SeriesRecord {
    init(_ row: StoredCalendarEvent) {
        uid = row.uid
        accountKey = row.accountKey
        eventID = row.eventID
        calendarID = row.calendarID
        wireUID = row.wireUID
        title = row.title
        startLocal = row.startLocal
        duration = row.duration
        timeZoneName = row.timeZoneName
        hasExplicitTimeZone = row.hasExplicitTimeZone
        showWithoutTime = row.showWithoutTime
        eventDescription = row.eventDescription
        locationName = row.locationName
        status = row.status
        privacy = row.privacy
        isRecurring = row.isRecurring
        kind = row.kind
        source = row.source
        sequence = row.sequence
        createdAt = row.createdAt
        updatedAt = row.updatedAt
        jsCalendarJSON = row.jsCalendarJSON
    }

    func apply(to row: StoredCalendarEvent) {
        row.calendarID = calendarID
        row.wireUID = wireUID
        row.title = title
        row.startLocal = startLocal
        row.duration = duration
        row.timeZoneName = timeZoneName
        row.hasExplicitTimeZone = hasExplicitTimeZone
        row.showWithoutTime = showWithoutTime
        row.eventDescription = eventDescription
        row.locationName = locationName
        row.status = status
        row.privacy = privacy
        row.isRecurring = isRecurring
        row.kind = kind
        row.source = source
        row.sequence = sequence
        row.createdAt = createdAt
        row.updatedAt = updatedAt
        row.jsCalendarJSON = jsCalendarJSON
    }

    func makeRow() -> StoredCalendarEvent {
        let row = StoredCalendarEvent(uid: uid, accountKey: accountKey, eventID: eventID)
        apply(to: row)

        return row
    }
}

extension CalendarWriteRollback.OccurrenceRecord {
    init(_ row: StoredCalendarOccurrence) {
        uid = row.uid
        accountKey = row.accountKey
        occurrenceID = row.occurrenceID
        seriesID = row.seriesID
        calendarID = row.calendarID
        recurrenceID = row.recurrenceID
        recurrenceIDTimeZone = row.recurrenceIDTimeZone
        startLocal = row.startLocal
        duration = row.duration
        startsAt = row.startsAt
        endsAt = row.endsAt
        dayKey = row.dayKey
        isAllDay = row.isAllDay
        title = row.title
        status = row.status
    }

    func apply(to row: StoredCalendarOccurrence) {
        row.calendarID = calendarID
        row.recurrenceID = recurrenceID
        row.recurrenceIDTimeZone = recurrenceIDTimeZone
        row.startLocal = startLocal
        row.duration = duration
        row.startsAt = startsAt
        row.endsAt = endsAt
        row.dayKey = dayKey
        row.isAllDay = isAllDay
        row.title = title
        row.status = status
    }

    func makeRow() -> StoredCalendarOccurrence {
        let row = StoredCalendarOccurrence(
            uid: uid, accountKey: accountKey, occurrenceID: occurrenceID, seriesID: seriesID)
        apply(to: row)

        return row
    }
}
