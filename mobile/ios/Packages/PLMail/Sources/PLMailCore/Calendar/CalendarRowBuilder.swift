import Foundation
public import JMAPKit

/// Joins an occurrence to its series and its calendar, once, into the value the
/// clusterer and the layout take.
///
/// The join has to happen somewhere: an occurrence row carries what the server
/// materialised, the zone belongs to the series, and the name and colour belong
/// to the calendar. Doing it per draw would be three lookups per chip per frame
/// of a scrolling month; doing it in the view would put the rule about which
/// zone wins into SwiftUI, where it cannot be tested.
public enum CalendarRowBuilder {
    /// `defaultZone` is the device's zone and is the last fallback for
    /// *ordering* an event nothing published a zone for. It is never used to
    /// convert a wall clock for display: a floating event says so instead.
    public static func rows(
        occurrences: [CalendarOccurrenceSnapshot],
        series: [CalendarEventID: CalendarEventSnapshot],
        calendars: [CalendarID: CalendarSnapshot],
        defaultZone: TimeZone
    ) -> [EventRow] {
        occurrences.compactMap { occurrence in
            guard let start = LocalDateTime(rawValue: occurrence.startLocal) else { return nil }

            let parent = series[occurrence.seriesID]
            let calendarID = occurrence.calendarID ?? parent?.calendarID
            let calendar = calendarID.flatMap { calendars[$0] }
            let end = start.end(after: occurrence.duration, isAllDay: occurrence.isAllDay)

            return EventRow(
                occurrenceID: occurrence.occurrenceID,
                seriesID: occurrence.seriesID,
                calendarID: calendarID,
                calendarName: calendar?.name,
                colourHex: calendar?.colorHex,
                uid: parent?.wireUID,
                title: occurrence.title,
                start: start,
                end: end,
                timeZoneName: zoneName(occurrence: occurrence, series: parent, calendar: calendar),
                isAllDay: occurrence.isAllDay,
                // **This occurrence's** status. Reading the series' instead
                // strikes out every sibling of one cancelled instance.
                isCancelled: occurrence.status == "cancelled",
                sortInstant: occurrence.startsAt
            )
        }
    }

    /// Which zone this occurrence's wall clock is read in, or nil for one that
    /// has none.
    ///
    /// Nil is a real answer, not missing data: an all-day event and a JSCalendar
    /// floating one have no instant at all, and giving them the device's zone is
    /// what makes the same birthday compare unequal to itself the day somebody
    /// travels.
    ///
    /// The order is the server's: the event's own published zone, then the
    /// calendar's — which is what an absent `timeZone` property means — and
    /// nothing after that.
    static func zoneName(
        occurrence: CalendarOccurrenceSnapshot,
        series: CalendarEventSnapshot?,
        calendar: CalendarSnapshot?
    ) -> String? {
        if occurrence.isAllDay { return nil }

        if let series {
            if let name = series.timeZoneName { return name }
            // An explicit `timeZone: null` on the wire. Floating, and not the
            // same thing as the property being absent.
            if series.hasExplicitTimeZone { return nil }
        }

        return calendar?.timeZone
    }

    /// Everything the visible window draws, clustered and in order.
    public static func clusters(
        occurrences: [CalendarOccurrenceSnapshot],
        series: [CalendarEventID: CalendarEventSnapshot],
        calendars: [CalendarID: CalendarSnapshot],
        defaultZone: TimeZone
    ) -> [EventCluster] {
        EventClusterer.cluster(
            rows(
                occurrences: occurrences,
                series: series,
                calendars: calendars,
                defaultZone: defaultZone
            ))
    }
}
