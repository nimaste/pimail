import Foundation

/// What the app hands the widget, decided in one pure function.
///
/// Separate from ``SharedCalendarState`` so the *rule* — which events count as
/// "still to come", how many, and in what order — is testable without a
/// simulator, a widget extension or an App Group. The App Group is the one part
/// of this feature that cannot be proven on this machine, so everything that
/// can be proven is kept on this side of the line.
public enum CalendarWidgetPlan {
    /// Today's events that have not finished, soonest first.
    ///
    /// **Filtered on the end, not the start.** A meeting that began ten minutes
    /// ago is the one thing a person glancing at their home screen most needs
    /// to see, and dropping it the moment it starts is how a widget becomes
    /// useless during the working day.
    ///
    /// All-day events sort first within the day, because that is where they are
    /// drawn everywhere else in this app and a widget that ordered them by a
    /// projected midnight would put a conference below a 09:00 standup on some
    /// devices and above it on others.
    ///
    /// - Parameters:
    ///   - clusters: everything the visible window holds. Filtered here rather
    ///     than by asking for a narrower window, because the widget is a
    ///     consequence of a refresh that already happened and must never be a
    ///     reason for one.
    ///   - today: the day being reported, so a test does not have to wait for
    ///     midnight.
    ///   - now: the moment "not finished yet" is measured against.
    ///   - timeText: how one row's time is spelled. Supplied by the caller
    ///     because the wording is localised and the formatter belongs to the
    ///     app, not to Core.
    /// - Returns: at most ``SharedCalendarState/limit`` events, all-day first
    ///   and then in start order.
    public static func upcoming(
        in clusters: [EventCluster],
        today: CalendarDay,
        now: Date,
        timeText: (EventCluster) -> String
    ) -> [SharedCalendarEvent] {
        clusters
            .filter { $0.representative.start.calendarDay == today }
            .filter { $0.representative.isAllDay || $0.representative.endsAfter(now) }
            .sorted { left, right in
                if left.representative.isAllDay != right.representative.isAllDay {
                    return left.representative.isAllDay
                }

                return left.representative.sortInstant < right.representative.sortInstant
            }
            .prefix(SharedCalendarState.limit)
            .map { cluster in
                let row = cluster.representative

                return SharedCalendarEvent(
                    id: row.occurrenceID.rawValue,
                    title: row.title,
                    timeText: timeText(cluster),
                    colourHex: row.colourHex,
                    calendarName: row.calendarName,
                    isAllDay: row.isAllDay,
                    startsAt: row.sortInstant,
                    // An all-day row has no instant of its own, so its end is
                    // the end of the day rather than a projection that would
                    // expire it at midday in half the world's zones.
                    endsAt: row.isAllDay
                        ? today.adding(days: 1).startOfDay(in: .current) : row.endInstant
                )
            }
    }

    /// When a widget's content next changes, as a set of timeline cut points.
    ///
    /// **A calendar knows exactly when it goes stale, which almost nothing else
    /// does.** Refreshing on a fixed cadence would either redraw a screen that
    /// has not changed dozens of times a day, or leave a finished meeting at
    /// the top of the list for fifteen minutes. Every end is a cut, plus the
    /// next midnight so that a day with nothing left in it turns over rather
    /// than showing yesterday.
    ///
    /// Always non-empty: an empty timeline is a widget the system never asks
    /// about again.
    public static func refreshPoints(
        for events: [SharedCalendarEvent], after now: Date, nextMidnight: Date
    ) -> [Date] {
        let ends = events.map(\.endsAt).filter { $0 > now }

        return ([now] + ends + [nextMidnight]).sorted()
    }
}

extension EventRow {
    /// This row's end as an instant, projected the same way ``sortInstant`` is.
    ///
    /// Only ever compared against `now` on this device. Never stored, never
    /// compared across devices: a floating event has no instant at all, and
    /// this is its wall clock resolved against one zone purely so that "has it
    /// finished" has an answer.
    ///
    /// The day difference is added explicitly rather than taking the minute
    /// difference alone: a 23:30 meeting running to 00:30 has an end whose
    /// minute-of-day is *smaller* than its start's, and a bare subtraction
    /// would report it as having finished an hour before it began.
    var endInstant: Date {
        let days = start.calendarDay.days(until: end.calendarDay)
        let minutes = days * 1440 + end.minuteOfDay - start.minuteOfDay

        return sortInstant.addingTimeInterval(Double(max(minutes, 0)) * 60)
    }

    func endsAfter(_ moment: Date) -> Bool { endInstant > moment }
}
