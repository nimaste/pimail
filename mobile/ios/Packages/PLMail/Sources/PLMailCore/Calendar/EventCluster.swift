import Foundation
public import JMAPKit

/// One drawable row: an occurrence, with everything a chip needs already
/// resolved.
///
/// A value type rather than the snapshot itself, because clustering and layout
/// are pure functions that have to be testable without a store — and because
/// the calendar's name and colour live on a different row from the occurrence,
/// so something has to join them once rather than at every draw.
public struct EventRow: Hashable, Sendable, Identifiable {
    /// The synthetic occurrence id. Opaque, never split.
    public let occurrenceID: CalendarEventID
    /// The series this belongs to — the only id `CalendarEvent/set` accepts,
    /// and the id a detail screen or an editor is addressed to.
    public let seriesID: CalendarEventID
    public let calendarID: CalendarID?
    /// For the accessibility label and for the merged-cluster description.
    /// Nil where the calendar list has not been refreshed yet, and **kept** as
    /// nil rather than dropped — see ``EventCluster/calendarNames``.
    public let calendarName: String?
    /// `#rrggbb`, unvalidated here: validation belongs where it is turned into
    /// a colour, and a row that fails it must still draw.
    public let colourHex: String?

    /// The JSCalendar `uid`. Half the collapse key, because one meeting
    /// legitimately reaches plMail twice — extracted from an invitation onto
    /// the account's calendar, and mirrored from a provider onto a connected
    /// one — and both rows are correct.
    public let uid: String?

    public let title: String

    /// Where the occurrence actually is, as a **wall clock**. Never converted
    /// to the device's zone: a floating event is the same clock everywhere, and
    /// a zoned one is drawn against the hour row its own clock names.
    public let start: LocalDateTime
    /// Start plus duration, in wall-clock terms. Precomputed because a day grid
    /// asks for it once per drawn day and parsing `PT15M` per draw is the hot
    /// path of a month.
    public let end: LocalDateTime

    /// The IANA zone the wall clocks above are read in, or nil for a floating
    /// or all-day event, which has no zone at all.
    public let timeZoneName: String?

    public let isAllDay: Bool

    /// **This occurrence's** status, not the series'. A single cancelled
    /// instance must not strike out its siblings.
    public let isCancelled: Bool

    /// For ordering only — the store's resolved projection.
    ///
    /// Never compared across devices and never used for placement: an all-day
    /// or floating occurrence has no instant at all, and this is its wall clock
    /// resolved against one zone purely so a day can be put in one order.
    public let sortInstant: Date

    public var id: CalendarEventID { occurrenceID }

    public init(
        occurrenceID: CalendarEventID,
        seriesID: CalendarEventID,
        calendarID: CalendarID? = nil,
        calendarName: String? = nil,
        colourHex: String? = nil,
        uid: String? = nil,
        title: String,
        start: LocalDateTime,
        end: LocalDateTime,
        timeZoneName: String? = nil,
        isAllDay: Bool = false,
        isCancelled: Bool = false,
        sortInstant: Date = .distantPast
    ) {
        self.occurrenceID = occurrenceID
        self.seriesID = seriesID
        self.calendarID = calendarID
        self.calendarName = calendarName
        self.colourHex = colourHex
        self.uid = uid
        self.title = title
        self.start = start
        self.end = end
        self.timeZoneName = timeZoneName
        self.isAllDay = isAllDay
        self.isCancelled = isCancelled
        self.sortInstant = sortInstant
    }

    /// How this row's start compares with another's, and the reason a zoned
    /// copy and a floating copy of the same meeting never merge.
    ///
    /// Where a zone is published the key is the **instant**, so 10:00
    /// Europe/Berlin and 09:00 Europe/London are the same moment and do
    /// collapse. Where none is, the key is the bare wall clock: an all-day or
    /// floating event has no instant at all, and resolving one against the
    /// device would make the same birthday compare unequal to itself the day
    /// somebody travels.
    public var startKey: String { Self.key(for: start, zone: timeZoneName) }

    /// The same rule for the end, which is one of the five facts a merge
    /// requires agreement on.
    public var endKey: String { Self.key(for: end, zone: timeZoneName) }

    static func key(for local: LocalDateTime, zone name: String?) -> String {
        guard let name, let zone = TimeZone(identifier: name), let instant = local.date(in: zone)
        else {
            return "floating/" + local.rawValue
        }

        return "instant/" + String(Int(instant.timeIntervalSince1970))
    }
}

/// One or more rows that are the **same meeting**, drawn once.
///
/// The collapse is the client's job: `docs/internals/calendar-model.md` lists
/// JMAP as the one reader deliberately left uncollapsed, because a protocol
/// that merged two rows would hand a client ids it cannot then `get`.
public struct EventCluster: Hashable, Sendable, Identifiable {
    /// In member order, never storage order — see ``EventClusterer``.
    public let members: [EventRow]

    /// The row a detail screen opens and a chip draws from. Deterministic by
    /// construction: a representative that moves between two renders of the
    /// same data is a detail screen that opens on a different copy each time it
    /// is tapped.
    public var representative: EventRow { members[0] }

    /// Whether more than one row was collapsed. **Must be said out loud** in
    /// the accessibility label: the multi-slice dot is invisible to VoiceOver
    /// and is otherwise the only signal that this happened.
    public var isMerged: Bool { members.count > 1 }

    /// Positional, in member order, and **nulls kept rather than dropped**. A
    /// calendar not yet refreshed has no colour, and dropping it would give a
    /// two-calendar meeting a one-colour dot — which says something untrue.
    public var colours: [String?] { members.map(\.colourHex) }

    /// Positional and in the same order as ``colours``, so the dot and the
    /// spoken description read in one order.
    public var calendarNames: [String?] { members.map(\.calendarName) }

    public var id: CalendarEventID { representative.occurrenceID }

    public init(members: [EventRow]) {
        self.members = members
    }
}

/// Collapses duplicate rows into clusters — a rule-for-rule port of the web's
/// `App\Service\Calendar\EventClusterer`.
public enum EventClusterer {
    /// Groups on **start plus uid**, and merges a group only while its members
    /// agree.
    ///
    /// Title and time alone would collapse a weekly 1:1 held with two different
    /// people at the same hour into one row — a meeting quietly disappearing
    /// from a calendar, which is the worst shape a calendar bug takes. Start is
    /// in the key because two occurrences of one series are the same *event*
    /// and not the same *meeting*.
    ///
    /// A row with **no uid** gets a key nothing can collide with, never the
    /// shared empty one.
    public static func cluster(_ rows: [EventRow]) -> [EventCluster] {
        var groups: [String: [EventRow]] = [:]
        var order: [String] = []

        for (index, row) in rows.enumerated() {
            let uid = row.uid.flatMap { $0.isEmpty ? nil : $0 } ?? "#\(index)"
            let key = row.startKey + "|" + uid

            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(row)
        }

        var clusters: [EventCluster] = []

        for key in order {
            let members = (groups[key] ?? []).sorted(by: precedes)

            if members.count > 1 && agrees(members) {
                clusters.append(EventCluster(members: members))
            } else {
                // **Splits entirely into clusters of one**, not into a majority
                // sub-group: a majority is a winner picked with extra steps,
                // and a merged row that quietly picked one would hide a real
                // disagreement behind a tidier UI.
                clusters.append(contentsOf: members.map { EventCluster(members: [$0]) })
            }
        }

        return clusters.sorted { left, right in
            if left.representative.sortInstant != right.representative.sortInstant {
                return left.representative.sortInstant < right.representative.sortInstant
            }

            return precedes(left.representative, right.representative)
        }
    }

    /// The five facts a user would notice, plus one row per calendar.
    ///
    /// Two rows on **one** calendar are two meetings by construction, since a
    /// uid is unique within a calendar — so they never merge however much they
    /// agree.
    ///
    /// **Recurrence is deliberately not one of the five.** Two copies where one
    /// repeats and the other does not agree about the occurrence they share and
    /// nothing else, and the repeating copy draws its own rows on later days
    /// with no partner — which is exactly the visible signal that they differ.
    static func agrees(_ members: [EventRow]) -> Bool {
        guard let first = members.first else { return false }

        var seenCalendars: Set<String> = []

        for member in members {
            guard member.startKey == first.startKey,
                member.endKey == first.endKey,
                member.title == first.title,
                member.isAllDay == first.isAllDay,
                member.isCancelled == first.isCancelled
            else { return false }

            // A row with no calendar id cannot be shown to be on a different
            // calendar from its neighbour, and merging on an unknown is how two
            // genuinely separate meetings become one.
            guard let calendarID = member.calendarID?.rawValue else { return false }
            guard seenCalendars.insert(calendarID).inserted else { return false }
        }

        return true
    }

    /// Member order: numeric id, then string id, then the series id.
    ///
    /// It has to be *decided* rather than inherited. The web is stable because
    /// its SQL ends `ORDER BY startsAt, id`; a local query ordered only by start
    /// hands ties back in storage order, and a representative that moves
    /// between two renders is a detail screen that opens on a different copy
    /// each time it is tapped.
    static func precedes(_ left: EventRow, _ right: EventRow) -> Bool {
        let leftNumber = Int(left.occurrenceID.rawValue)
        let rightNumber = Int(right.occurrenceID.rawValue)

        switch (leftNumber, rightNumber) {
        case (.some(let a), .some(let b)) where a != b:
            return a < b
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            break
        }

        if left.occurrenceID.rawValue != right.occurrenceID.rawValue {
            return left.occurrenceID.rawValue < right.occurrenceID.rawValue
        }

        return left.seriesID.rawValue < right.seriesID.rawValue
    }
}
