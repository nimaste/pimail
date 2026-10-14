import Foundation
public import JMAPKit

/// The sentence a row, chip or cell says out loud.
///
/// In Core rather than in the view, and pure, because a grid is the surface
/// where "it technically works" is furthest from usable: the label is the
/// entire interface for a VoiceOver reader, and a label composed inside a
/// `ViewBuilder` is a label no test ever reads.
public enum EventSpeech {
    /// Formats a wall clock **without converting it to anywhere**.
    ///
    /// The instant is constructed in UTC and formatted in UTC purely so that
    /// what comes out is the same clock that went in. Formatting through the
    /// device's zone would move every event by the difference, which is
    /// precisely the bug this whole feature is careful about.
    public static func time(_ local: LocalDateTime, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = .gmt
        formatter.calendar = CalendarDay.arithmetic(in: .gmt)
        formatter.dateFormat =
            DateFormatter.dateFormat(fromTemplate: "jm", options: 0, locale: locale) ?? "HH:mm"

        let day = local.calendarDay
        let base = day.startOfDay(in: .gmt)
            .addingTimeInterval(Double(local.minuteOfDay) * 60)

        return formatter.string(from: base)
    }

    /// "09:00 – 09:15", or the localised word for all day.
    public static func timeSpan(
        _ cluster: EventCluster,
        locale: Locale,
        allDayWord: String
    ) -> String {
        let row = cluster.representative

        if row.isAllDay { return allDayWord }

        return time(row.start, locale: locale) + " – " + time(row.end, locale: locale)
    }

    /// Title, time span, calendar — and, when rows were collapsed, **that they
    /// were**.
    ///
    /// The multi-slice dot is invisible to VoiceOver and is otherwise the only
    /// signal that two rows became one, so a merged cluster has to say so and
    /// name the calendars it merged across.
    ///
    /// `mergedPhrase` is a localised closure taking the number of calendars and
    /// their names, because the wording and the list separator are both
    /// language decisions and neither belongs in Core.
    public static func label(
        for cluster: EventCluster,
        locale: Locale,
        allDayWord: String,
        floatingWord: String?,
        cancelledWord: String?,
        mergedPhrase: (Int, [String]) -> String
    ) -> String {
        let row = cluster.representative
        var parts: [String] = [row.title.isEmpty ? " " : row.title]

        parts.append(timeSpan(cluster, locale: locale, allDayWord: allDayWord))

        if let name = row.calendarName, name.isEmpty == false { parts.append(name) }

        // A floating event has no zone at all, so its time means the same clock
        // wherever it is read. Saying so is the only way a reader can tell it
        // apart from one that happens to be in theirs.
        if let floatingWord, row.isAllDay == false, row.timeZoneName == nil {
            parts.append(floatingWord)
        }

        if let cancelledWord, row.isCancelled { parts.append(cancelledWord) }

        if cluster.isMerged {
            let names = cluster.calendarNames.compactMap { $0 }

            parts.append(mergedPhrase(cluster.members.count, names))
        }

        return parts.joined(separator: ", ")
    }
}
