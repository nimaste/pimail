import Foundation
public import JMAPKit

/// Search over **what is cached**, and only over that.
///
/// `CalendarEvent/query` accepts `inCalendar`, `after` and `before` and refuses
/// everything else — there is no `text` condition on the wire at all. So this
/// is local by necessity rather than by choice, and the screen has to say so:
/// a result list that silently covers only the dates somebody happens to have
/// opened reads as a broken search rather than as a narrow one.
///
/// Pure and `static` so the matching rule is testable without a store, a
/// simulator or a server.
public enum CalendarSearch {
    /// The fields a query is compared against.
    ///
    /// Title alone is not enough — "dentist" is as likely to be in the notes as
    /// in the title, and a location is what people actually remember about a
    /// meeting they cannot name. The calendar's own name is included so that
    /// "work" narrows to a calendar without a separate filter control.
    ///
    /// The series' description and location come from a **separate row** from
    /// the occurrence, so they are passed in rather than read off the cluster:
    /// a caller that has not loaded the series yet still gets title and
    /// calendar matches instead of nothing.
    public static func matches(
        _ cluster: EventCluster,
        query: String,
        series: CalendarEventSnapshot?
    ) -> Bool {
        let needle = normalise(query)

        guard needle.isEmpty == false else { return true }

        var haystack = [cluster.representative.title]
        haystack += cluster.calendarNames.compactMap { $0 }
        haystack += [series?.locationName, series?.eventDescription].compactMap { $0 }

        return haystack.contains { normalise($0).contains(needle) }
    }

    /// The visible clusters a query keeps, in the order they were given.
    ///
    /// Order is preserved rather than ranked. A calendar search is answering
    /// "where is it in the week", so chronological is the useful order and a
    /// relevance score would move a Tuesday above a Monday for reasons the
    /// reader cannot see.
    public static func filter(
        _ clusters: [EventCluster],
        query: String,
        series: [CalendarEventID: CalendarEventSnapshot] = [:]
    ) -> [EventCluster] {
        guard normalise(query).isEmpty == false else { return clusters }

        return clusters.filter {
            matches($0, query: query, series: series[$0.representative.seriesID])
        }
    }

    /// Case- and diacritic-insensitive, and folded with the **current** locale.
    ///
    /// Without folding, a German user searching `burodrucker` never finds
    /// *Bürodrucker*, and the failure looks like a missing event rather than a
    /// missing fold.
    private static func normalise(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
