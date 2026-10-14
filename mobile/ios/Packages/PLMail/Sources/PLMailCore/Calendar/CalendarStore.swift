import Foundation
public import JMAPKit
import OSLog
import SwiftData

/// The only thing that writes calendar rows.
///
/// A second `@ModelActor` over the **same container** as `SyncStore` rather
/// than more methods on it: mail's writer batches per sync unit and a calendar
/// refresh is a different unit with a different failure mode, and the two are
/// edited by different people. One container, two writers, no shared context —
/// SwiftData propagates saves from either to the main context, so `@Query`
/// re-runs the same way.
///
/// Everything here is cache in the strict sense `SchemaV1`'s banner means: the
/// server materialises occurrences and this client never expands a recurrence
/// rule itself, so every row is re-fetchable from one windowed query and
/// nothing here is an answer only this device holds.
@ModelActor
public actor CalendarStore {
    private static let logger = Logger(subsystem: "de.plmail", category: "calendar")

    /// The occurrence properties this client asks for.
    ///
    /// `CalendarEventGet.occurrenceProperties` is the wire's own economical
    /// list and it omits `calendarId` — which the duplicate collapse cannot do
    /// without, since "two rows on one calendar are two meetings" is one of the
    /// facts a merge is decided on. Deriving it from the series instead would
    /// work only while the collapsed query is guaranteed to carry every series
    /// the expanded one names, which is a guarantee about two separate queries
    /// that nothing enforces.
    public static let occurrenceProperties =
        CalendarEventGet.occurrenceProperties + ["calendarId"]

    // MARK: - Calendars

    /// Replaces the calendar list wholesale.
    ///
    /// Wholesale rather than merged because `Calendar/get` with `ids: null`
    /// **is** the whole list — there is no `Calendar/changes` to diff against —
    /// so a calendar missing from the answer is a calendar that is gone, and
    /// keeping it would leave a tick in the sidebar for something the server
    /// will refuse every query about.
    @discardableResult
    public func replaceCalendars(
        _ calendars: [JMAPCalendar],
        accountKey: String
    ) throws -> [CalendarSnapshot] {
        var live: Set<String> = []

        for calendar in calendars {
            let uid = StoreKey.object(accountKey: accountKey, id: calendar.id.rawValue)
            live.insert(uid)

            let stored =
                try existingCalendar(uid: uid)
                ?? {
                    let row = StoredCalendar(
                        uid: uid,
                        accountKey: accountKey,
                        calendarID: calendar.id.rawValue,
                        name: calendar.name ?? ""
                    )
                    modelContext.insert(row)

                    return row
                }()

            if let name = calendar.name { stored.name = name }
            stored.colorHex = calendar.color
            stored.sortOrder = calendar.sortOrder ?? stored.sortOrder
            stored.isVisible = calendar.isVisible ?? true
            stored.isDefault = calendar.isDefault ?? false
            stored.timeZone = calendar.timeZone
            stored.role = calendar.role?.rawValue
            stored.isSynced = calendar.isSynced ?? false
            // Absent rights read as **not** writable. A `properties` filter
            // that omitted `myRights` has told us nothing, and offering a write
            // on nothing is the refusal this defaults away from.
            stored.mayReadItems = calendar.myRights?.mayReadItems ?? true
            stored.mayAddItems = calendar.myRights?.mayAddItems ?? false
            stored.mayUpdateAll = calendar.myRights?.mayUpdateAll ?? false
            stored.mayRemoveItems = calendar.myRights?.mayRemoveItems ?? false
            stored.mayDelete = calendar.myRights?.mayDelete ?? false
        }

        for stale in try allCalendars(accountKey: accountKey)
        where live.contains(stale.uid) == false {
            modelContext.delete(stale)
        }

        try modelContext.save()

        return try self.calendars(accountKey: accountKey)
    }

    public func calendars(accountKey: String) throws -> [CalendarSnapshot] {
        try allCalendars(accountKey: accountKey)
            .sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
            .map(snapshot(of:))
    }

    /// Every calendar this device holds, across accounts.
    ///
    /// What the availability probe reads: "is there a calendar on this device"
    /// is a question a cold launch on a train has to answer without asking the
    /// server which account owns one.
    /// The account key calendar rows are actually filed under, read back from
    /// the cache.
    ///
    /// **The offline half of availability.** The key is normally built from the
    /// session's calendar account id, and a launch with no network has no
    /// session — so `accountKey` was nil, `calendars(accountKey: "")` matched
    /// nothing, and a month of perfectly good cached events drew with no
    /// calendar colours, no calendar names and an empty sidebar. Seen on a
    /// 13-inch iPad against an unreachable host.
    ///
    /// Nil when nothing has ever been cached, which is the one case where
    /// answering "no calendars" is true.
    public func storedAccountKey() throws -> String? {
        var descriptor = FetchDescriptor<StoredCalendar>(
            sortBy: [SortDescriptor(\.accountKey)])
        descriptor.fetchLimit = 1

        return try modelContext.fetch(descriptor).first?.accountKey
    }

    public func calendarCount() throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<StoredCalendar>())
    }

    // MARK: - Series

    /// Upserts event series, leaving anything the answer did not mention alone.
    ///
    /// Upsert rather than replace because a series is reached by two different
    /// queries and edited through a third path: overwriting the set would drop
    /// a series whose only occurrence in this window was cancelled, and with it
    /// the row an editor is addressed to.
    public func upsertSeries(_ events: [CalendarEvent], accountKey: String) throws {
        for event in events {
            // An occurrence is not a series. It arrives with the same id space
            // and would otherwise be stored as one, giving the editor an id
            // `CalendarEvent/set` refuses by name.
            guard event.isOccurrence == false else { continue }

            let uid = StoreKey.object(accountKey: accountKey, id: event.id.rawValue)
            let stored =
                try existingSeries(uid: uid)
                ?? {
                    let row = StoredCalendarEvent(
                        uid: uid, accountKey: accountKey, eventID: event.id.rawValue)
                    modelContext.insert(row)

                    return row
                }()

            stored.calendarID = event.calendarID?.rawValue ?? stored.calendarID
            stored.wireUID = event.uid ?? stored.wireUID
            stored.title = event.title ?? stored.title
            stored.startLocal = event.start?.rawValue ?? stored.startLocal
            stored.duration = event.duration ?? stored.duration
            // The three-state zone, kept as two fields. `hasExplicitTimeZone`
            // false is "the property was absent — use the calendar's zone";
            // true with a nil name is JSCalendar floating, which is what every
            // all-day event is. Collapsing the two zones every floating event
            // this client sends back.
            stored.timeZoneName = event.timeZone
            stored.hasExplicitTimeZone = event.timeZone != nil || event.showWithoutTime == true
            stored.showWithoutTime = event.showWithoutTime ?? stored.showWithoutTime
            stored.eventDescription = event.description ?? stored.eventDescription
            stored.locationName = event.locationName ?? stored.locationName
            stored.status = event.status?.rawValue ?? stored.status
            stored.privacy = event.privacy?.rawValue ?? stored.privacy
            stored.isRecurring = event.isRecurring ?? stored.isRecurring
            stored.kind = event.kind?.rawValue ?? stored.kind
            stored.source = event.source?.rawValue ?? stored.source
            stored.sequence = event.sequence ?? stored.sequence
            stored.createdAt = event.created?.date ?? stored.createdAt
            stored.updatedAt = event.updated?.date ?? stored.updatedAt
        }

        try modelContext.save()
    }

    /// The canonical body, stored verbatim beside the projected columns.
    ///
    /// Separate from ``upsertSeries(_:accountKey:)`` because the two arrive
    /// from different gets: a windowed refresh asks for the drawing fields
    /// only, and the whole body is worth moving over a domestic uplink once,
    /// when somebody opens the event. An editor patches **from** this rather
    /// than rebuilding it, because an import can carry JSCalendar this build
    /// has never heard of and a rebuild deletes it on save.
    public func storeBody(_ json: Data, eventID: CalendarEventID, accountKey: String) throws {
        let uid = StoreKey.object(accountKey: accountKey, id: eventID.rawValue)

        guard let stored = try existingSeries(uid: uid) else { return }

        stored.jsCalendarJSON = json
        try modelContext.save()
    }

    public func series(id: CalendarEventID, accountKey: String) throws -> CalendarEventSnapshot? {
        let uid = StoreKey.object(accountKey: accountKey, id: id.rawValue)

        return try existingSeries(uid: uid).map(snapshot(of:))
    }

    // MARK: - Occurrences

    /// Replaces every occurrence inside `window` with what the server just
    /// said, then sweeps series nothing places any more.
    ///
    /// **Replace rather than upsert, and only within the window.** There is no
    /// `/changes` to diff against, so an occurrence that has been cancelled,
    /// excluded or moved out of the window is recognisable only by its absence
    /// from the answer — and an upsert would leave it on the grid for ever,
    /// which is a meeting that cannot be deleted from a phone.
    ///
    /// Outside the window nothing is touched, because this answer says nothing
    /// about it.
    @discardableResult
    public func replaceOccurrences(
        _ events: [CalendarEvent],
        in window: CalendarWindow,
        accountKey: String,
        zone: TimeZone,
        calendarZones: [String: String] = [:]
    ) throws -> Int {
        let fromKey = window.from.key
        let toKey = window.to.key

        // Filtered in Swift rather than in one three-clause `#Predicate`:
        // SwiftData's macro cannot type-check the compound form in reasonable
        // time, and a window is at most 366 days of one account's rows.
        let stale = try modelContext.fetch(
            FetchDescriptor<StoredCalendarOccurrence>(
                predicate: #Predicate { $0.accountKey == accountKey }))

        for row in stale where row.dayKey >= fromKey && row.dayKey < toKey {
            modelContext.delete(row)
        }

        var written = 0

        for event in events {
            guard let startText = event.start?.rawValue,
                let start = LocalDateTime(rawValue: startText)
            else { continue }

            // `seriesId` is present exactly when the id names an occurrence; a
            // one-off keeps its plain series id even in an expanded answer, and
            // then it *is* its own series.
            let seriesID = event.seriesID ?? event.id
            let day = start.calendarDay

            // The answer reaches a day either side of the window, because the
            // fetch bounds are a union of two readings of it. Placement drops
            // the overhang rather than storing rows the window's next refresh
            // would not replace.
            guard window.contains(day) else { continue }

            let uid = StoreKey.object(accountKey: accountKey, id: event.id.rawValue)
            let row = StoredCalendarOccurrence(
                uid: uid,
                accountKey: accountKey,
                occurrenceID: event.id.rawValue,
                seriesID: seriesID.rawValue
            )

            let isAllDay = event.showWithoutTime ?? false
            let end = start.end(after: event.duration, isAllDay: isAllDay)
            let resolved =
                event.timeZone
                ?? event.calendarID.flatMap { calendarZones[$0.rawValue] }
            let placement = resolved.flatMap(TimeZone.init(identifier:)) ?? zone

            row.calendarID = event.calendarID?.rawValue
            row.recurrenceID = event.recurrenceID?.rawValue ?? startText
            row.recurrenceIDTimeZone = event.recurrenceIDTimeZone
            row.startLocal = startText
            row.duration = event.duration
            row.startsAt = start.date(in: placement) ?? day.startOfDay(in: placement)
            row.endsAt = end.date(in: placement) ?? row.startsAt
            row.dayKey = day.key
            row.isAllDay = isAllDay
            row.title = event.title ?? ""
            row.status = event.status?.rawValue

            modelContext.insert(row)
            written += 1
        }

        try modelContext.save()
        try sweepUnplacedSeries(accountKey: accountKey)

        return written
    }

    /// Deletes series with no occurrence anywhere in the cache.
    ///
    /// A series with nothing placed cannot be drawn and cannot be reached, so
    /// keeping it is keeping a row that grows without bound as the user pages
    /// through months. Safe precisely because the store is a cache: the editor
    /// re-fetches a series by id before it writes.
    private func sweepUnplacedSeries(accountKey: String) throws {
        let placed = Set(
            try modelContext.fetch(
                FetchDescriptor<StoredCalendarOccurrence>(
                    predicate: #Predicate { $0.accountKey == accountKey }
                )
            ).map(\.seriesID))

        var removed = 0

        for series in try modelContext.fetch(
            FetchDescriptor<StoredCalendarEvent>(
                predicate: #Predicate { $0.accountKey == accountKey })
        ) where placed.contains(series.eventID) == false {
            modelContext.delete(series)
            removed += 1
        }

        if removed > 0 {
            Self.logger.debug("Swept \(removed, privacy: .public) unplaced calendar series")
            try modelContext.save()
        }
    }

    /// What a view draws: every occurrence whose local day falls in the window,
    /// in start order.
    public func occurrences(
        in window: CalendarWindow, accountKey: String? = nil
    )
        throws -> [CalendarOccurrenceSnapshot]
    {
        let fromKey = window.from.key
        let toKey = window.to.key

        var descriptor = FetchDescriptor<StoredCalendarOccurrence>(
            predicate: #Predicate { $0.dayKey >= fromKey },
            sortBy: [SortDescriptor(\.startsAt), SortDescriptor(\.occurrenceID)]
        )
        descriptor.fetchLimit = 5000

        let rows = try modelContext.fetch(descriptor)

        return
            rows
            .filter { $0.dayKey < toKey && (accountKey == nil || $0.accountKey == accountKey) }
            .map(snapshot(of:))
    }

    /// Every cached occurrence for an account, newest window and oldest alike.
    ///
    /// For ``CalendarSpotlightIndex`` and for nothing else. A view asks for a
    /// window because a view draws one; the index has to reconcile against the
    /// *whole* cache, since an entry the cache no longer holds is an entry that
    /// must come out of system search — and enumerating windows to find that
    /// out would mean guessing which windows were ever visited.
    ///
    /// **Never a reason to fetch.** It reads what a refresh already stored.
    public func allOccurrences(
        accountKey: String, limit: Int = 5000
    ) throws -> [CalendarOccurrenceSnapshot] {
        var descriptor = FetchDescriptor<StoredCalendarOccurrence>(
            predicate: #Predicate { $0.accountKey == accountKey },
            sortBy: [SortDescriptor(\.startsAt), SortDescriptor(\.occurrenceID)]
        )
        descriptor.fetchLimit = limit

        return try modelContext.fetch(descriptor).map(snapshot(of:))
    }

    /// One occurrence by its synthetic id, or nil when the cache no longer
    /// holds it.
    ///
    /// **The whole point is the nil.** A Spotlight result, a Handoff payload
    /// and a restored scene value are all written at one moment and acted on at
    /// another, and in between the meeting can be cancelled, the window
    /// re-queried and the row dropped. Reading the id straight back out of the
    /// cache is what lets that arrive as "this is not here any more" rather
    /// than as an empty screen with a title on it.
    ///
    /// A keyed read rather than a filter over ``allOccurrences(accountKey:limit:)``:
    /// the uid is the unique index, so this is one row rather than a scan over
    /// every occurrence a year of browsing has left behind.
    public func occurrence(
        _ id: CalendarEventID, accountKey: String
    ) throws -> CalendarOccurrenceSnapshot? {
        let uid = StoreKey.object(accountKey: accountKey, id: id.rawValue)

        var descriptor = FetchDescriptor<StoredCalendarOccurrence>(
            predicate: #Predicate { $0.uid == uid })
        descriptor.fetchLimit = 1

        return try modelContext.fetch(descriptor).first.map(snapshot(of:))
    }

    // MARK: - Optimistic writes

    /// Everything about one series, before it is touched.
    ///
    /// Taken **before** the optimistic edit and held across the round trip, so
    /// a refusal or a dropped connection can put the cache back exactly as it
    /// was. There is no `ifInState` and no queue here: a write either landed or
    /// never happened, and the second case must be indistinguishable from not
    /// having pressed the button.
    public func captureRollback(
        for id: CalendarEventID, accountKey: String
    ) throws -> CalendarWriteRollback {
        let uid = StoreKey.object(accountKey: accountKey, id: id.rawValue)

        return CalendarWriteRollback(
            accountKey: accountKey,
            seriesID: id,
            series: try existingSeries(uid: uid).map(CalendarWriteRollback.SeriesRecord.init),
            occurrences: try occurrenceRows(of: id, accountKey: accountKey)
                .map(CalendarWriteRollback.OccurrenceRecord.init)
        )
    }

    /// Applies an edit to the cache before the server has answered.
    ///
    /// The series row takes every field the editor owns. The occurrence rows
    /// take only the **title and the all-day flag**, and their times move only
    /// when the series does not recur — this client may not expand a recurrence
    /// rule, so where a moved start lands for every other instance is a
    /// question only the server can answer, and the refresh that follows a
    /// successful write is what asks it.
    public func applyLocally(
        _ draft: EventDraft, to id: CalendarEventID, accountKey: String
    ) throws {
        let uid = StoreKey.object(accountKey: accountKey, id: id.rawValue)

        guard let series = try existingSeries(uid: uid) else { return }

        series.calendarID = draft.calendarID.rawValue
        series.title = draft.title
        series.startLocal = draft.start.rawValue
        series.duration = draft.duration.wireValue
        series.showWithoutTime = draft.isAllDay
        series.locationName = draft.location
        series.eventDescription = draft.notes

        let moves = series.isRecurring == false

        for row in try occurrenceRows(of: id, accountKey: accountKey) {
            row.title = draft.title
            row.isAllDay = draft.isAllDay

            guard moves else { continue }

            let day = draft.start.calendarDay
            let placement = zone(for: row, series: series, accountKey: accountKey)
            row.startLocal = draft.start.rawValue
            row.duration = draft.duration.wireValue
            row.startsAt = draft.start.date(in: placement) ?? day.startOfDay(in: placement)
            row.endsAt = draft.end.date(in: placement) ?? row.startsAt
            row.dayKey = day.key
        }

        try modelContext.save()
    }

    /// Removes a series and every occurrence of it, before the server has
    /// answered.
    ///
    /// **The whole series**, because that is what a destroy does: there is no
    /// writable id for a single occurrence, so removing one instance is a
    /// `recurrenceOverrides` entry marking it excluded rather than a delete.
    public func removeLocally(_ id: CalendarEventID, accountKey: String) throws {
        for row in try occurrenceRows(of: id, accountKey: accountKey) {
            modelContext.delete(row)
        }

        let uid = StoreKey.object(accountKey: accountKey, id: id.rawValue)

        if let series = try existingSeries(uid: uid) { modelContext.delete(series) }

        try modelContext.save()
    }

    /// Puts back exactly what ``captureRollback(for:accountKey:)`` recorded.
    ///
    /// Rows that exist are overwritten and rows that are gone are re-inserted,
    /// so this restores an update and a delete through the same path. Anything
    /// the optimistic edit added and the record does not name is removed:
    /// leaving it would be a row the next refresh has no reason to touch.
    public func rollBack(_ rollback: CalendarWriteRollback) throws {
        let accountKey = rollback.accountKey
        let uid = StoreKey.object(accountKey: accountKey, id: rollback.seriesID.rawValue)

        if let record = rollback.series {
            if let row = try existingSeries(uid: uid) {
                record.apply(to: row)
            } else {
                modelContext.insert(record.makeRow())
            }
        } else if let row = try existingSeries(uid: uid) {
            modelContext.delete(row)
        }

        let wanted = Dictionary(
            rollback.occurrences.map { ($0.uid, $0) }, uniquingKeysWith: { first, _ in first })
        var present: Set<String> = []

        for row in try occurrenceRows(of: rollback.seriesID, accountKey: accountKey) {
            guard let record = wanted[row.uid] else {
                modelContext.delete(row)
                continue
            }

            record.apply(to: row)
            present.insert(row.uid)
        }

        for record in rollback.occurrences where present.contains(record.uid) == false {
            modelContext.insert(record.makeRow())
        }

        try modelContext.save()
    }

    private func occurrenceRows(
        of id: CalendarEventID, accountKey: String
    ) throws -> [StoredCalendarOccurrence] {
        let seriesID = id.rawValue

        return try modelContext.fetch(
            FetchDescriptor<StoredCalendarOccurrence>(
                predicate: #Predicate {
                    $0.accountKey == accountKey && $0.seriesID == seriesID
                }))
    }

    /// The zone an occurrence's wall clocks are resolved against for ordering.
    ///
    /// The series' own zone, then the calendar's, then UTC — deliberately
    /// **not** the device's. `startsAt` is a projection used to put a day in
    /// order, and a projection that moved with the reader would reorder a day
    /// the moment somebody travelled.
    private func zone(
        for row: StoredCalendarOccurrence, series: StoredCalendarEvent, accountKey: String
    ) -> TimeZone {
        let name =
            series.timeZoneName
            ?? (row.calendarID ?? series.calendarID).flatMap { id in
                try? existingCalendar(
                    uid: StoreKey.object(accountKey: accountKey, id: id))?.timeZone
            } ?? nil

        return name.flatMap(TimeZone.init(identifier:)) ?? .gmt
    }

    /// Drops every calendar row for an account. Used when the server stops
    /// publishing a calendar account: leaving the rows would draw a calendar
    /// the server will refuse every query about.
    public func deleteCalendarData(accountKey: String) throws {
        for row in try modelContext.fetch(
            FetchDescriptor<StoredCalendarOccurrence>(
                predicate: #Predicate { $0.accountKey == accountKey }))
        {
            modelContext.delete(row)
        }

        for row in try modelContext.fetch(
            FetchDescriptor<StoredCalendarEvent>(
                predicate: #Predicate { $0.accountKey == accountKey }))
        {
            modelContext.delete(row)
        }

        for row in try allCalendars(accountKey: accountKey) { modelContext.delete(row) }

        try modelContext.save()
    }

    // MARK: - Fetching

    private func allCalendars(accountKey: String) throws -> [StoredCalendar] {
        try modelContext.fetch(
            FetchDescriptor<StoredCalendar>(
                predicate: #Predicate { $0.accountKey == accountKey }))
    }

    private func existingCalendar(uid: String) throws -> StoredCalendar? {
        var descriptor = FetchDescriptor<StoredCalendar>(
            predicate: #Predicate { $0.uid == uid })
        descriptor.fetchLimit = 1

        return try modelContext.fetch(descriptor).first
    }

    private func existingSeries(uid: String) throws -> StoredCalendarEvent? {
        var descriptor = FetchDescriptor<StoredCalendarEvent>(
            predicate: #Predicate { $0.uid == uid })
        descriptor.fetchLimit = 1

        return try modelContext.fetch(descriptor).first
    }

    // MARK: - Snapshots

    private func snapshot(of calendar: StoredCalendar) -> CalendarSnapshot {
        var snapshot = CalendarSnapshot(
            accountKey: calendar.accountKey,
            calendarID: CalendarID(rawValue: calendar.calendarID),
            name: calendar.name
        )
        snapshot.colorHex = calendar.colorHex
        snapshot.sortOrder = calendar.sortOrder
        snapshot.isVisible = calendar.isVisible
        snapshot.isDefault = calendar.isDefault
        snapshot.timeZone = calendar.timeZone
        snapshot.role = calendar.role
        snapshot.isSynced = calendar.isSynced
        snapshot.mayAddItems = calendar.mayAddItems
        snapshot.mayUpdateAll = calendar.mayUpdateAll
        snapshot.mayRemoveItems = calendar.mayRemoveItems

        return snapshot
    }

    private func snapshot(of event: StoredCalendarEvent) -> CalendarEventSnapshot {
        var snapshot = CalendarEventSnapshot(
            accountKey: event.accountKey,
            eventID: CalendarEventID(rawValue: event.eventID),
            title: event.title,
            startLocal: event.startLocal
        )
        snapshot.calendarID = event.calendarID.map { CalendarID(rawValue: $0) }
        snapshot.wireUID = event.wireUID
        snapshot.duration = event.duration
        snapshot.timeZoneName = event.timeZoneName
        snapshot.hasExplicitTimeZone = event.hasExplicitTimeZone
        snapshot.showWithoutTime = event.showWithoutTime
        snapshot.eventDescription = event.eventDescription
        snapshot.locationName = event.locationName
        snapshot.status = event.status
        snapshot.privacy = event.privacy
        snapshot.isRecurring = event.isRecurring
        snapshot.kind = event.kind
        snapshot.source = event.source
        snapshot.sequence = event.sequence
        snapshot.jsCalendarJSON = event.jsCalendarJSON

        return snapshot
    }

    private func snapshot(of row: StoredCalendarOccurrence) -> CalendarOccurrenceSnapshot {
        var snapshot = CalendarOccurrenceSnapshot(
            accountKey: row.accountKey,
            occurrenceID: CalendarEventID(rawValue: row.occurrenceID),
            seriesID: CalendarEventID(rawValue: row.seriesID),
            recurrenceID: row.recurrenceID,
            startLocal: row.startLocal,
            startsAt: row.startsAt,
            endsAt: row.endsAt,
            title: row.title
        )
        snapshot.calendarID = row.calendarID.map { CalendarID(rawValue: $0) }
        snapshot.recurrenceIDTimeZone = row.recurrenceIDTimeZone
        snapshot.duration = row.duration
        snapshot.isAllDay = row.isAllDay
        snapshot.status = row.status

        return snapshot
    }
}
