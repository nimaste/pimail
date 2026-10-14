import Foundation
public import JMAPKit
import OSLog
import Observation

/// Drives the calendar: what window is on screen, what the cache holds for it,
/// and when the server is asked again.
///
/// **There is no timer, no background task and no push subscription here, and
/// there must never be one.** `Calendar/get`, `CalendarEvent/get`, `/query` and
/// `/set` all return the literal state `"fixed"` and `canCalculateChanges` is
/// false, so there is no delta to poll for and nothing that could wake the app
/// because an event changed. Freshness comes from re-running the visible
/// window's query while somebody is looking at it, and from nothing else —
/// which is also what the server's own client guidance demands, since this
/// audience runs plMail on a Raspberry Pi with a single PHP worker pool.
@MainActor
@Observable
public final class CalendarService {
    public enum Status: Equatable, Sendable {
        case idle
        case refreshing
        /// The last refresh did not produce data. The cache still draws, so
        /// this is a banner over content rather than a replacement for it.
        case failed(CalendarRefresh)
    }

    public private(set) var status: Status = .idle

    /// The calendars, in sidebar order. Their `isVisible` is honoured as the
    /// **initial** state of a local toggle and never as a query filter — the
    /// server's own docblock says a client filtering on it would hide from a
    /// phone what its user chose to hide in a browser.
    public private(set) var calendars: [CalendarSnapshot] = []

    /// The window currently drawn, and what it draws.
    public private(set) var window: CalendarWindow?
    public private(set) var clusters: [EventCluster] = []

    /// The series behind the visible occurrences, keyed by series id.
    ///
    /// Published rather than kept inside the cache read because **search has to
    /// reach the notes and the location**, and both live on the series row
    /// rather than the occurrence. `CalendarEvent/query` refuses every
    /// condition but `inCalendar`, `after` and `before`, so there is no
    /// server-side text search to fall back on and a local one that could only
    /// see titles would silently miss the half of the matches people actually
    /// look for.
    public private(set) var seriesByID: [CalendarEventID: CalendarEventSnapshot] = [:]

    /// True when the horizon clamp trimmed the request. The screens show a
    /// footer rather than stopping silently.
    public private(set) var mayBeIncomplete = false

    /// When the visible window was last successfully refreshed.
    ///
    /// Held because a write involving recurrence has to re-ask the server where
    /// the occurrences landed — reconstructing them from a rule locally is the
    /// one thing this client may not do.
    public private(set) var lastRefreshedAt: Date?

    public let availability: CalendarAvailability

    /// Which calendars the user has hidden **on this device**, kept apart from
    /// the server's `isVisible` so that toggling one here does not pretend to
    /// have changed the other.
    public private(set) var locallyHidden: Set<CalendarID> = []

    let client: JMAPClient
    private let store: CalendarStore
    private let serverID: String
    private let zone: () -> TimeZone
    private let today: () -> CalendarDay
    private let logger = Logger(subsystem: "de.plmail", category: "calendar")

    /// One refresh at a time. A mode change and an appear can land in the same
    /// frame, and two overlapping refreshes of overlapping windows would
    /// delete each other's rows between the fetch and the write.
    private var inFlight: Task<CalendarRefresh, Never>?

    public init(
        client: JMAPClient,
        store: CalendarStore,
        serverID: String,
        availability: CalendarAvailability,
        zone: @escaping () -> TimeZone = { .current },
        today: @escaping () -> CalendarDay = { CalendarDay(.now, in: .current) }
    ) {
        self.client = client
        self.store = store
        self.serverID = serverID
        self.availability = availability
        self.zone = zone
        self.today = today
    }

    /// The store key calendar rows are filed under. Calendars are user-scoped
    /// server-side, so this records *which* account answered rather than
    /// partitioning anything.
    ///
    /// Falls back to ``cachedAccountKey`` because the session is what names the
    /// account and a launch with no network has no session. Without the
    /// fallback an offline calendar drew its events with **no colours, no
    /// calendar names and an empty sidebar** — the occurrence query treats a
    /// nil key as "any account" and the calendar query does not.
    private var accountKey: String? {
        availability.accountID.map { StoreKey.account(server: serverID, account: $0) }
            ?? cachedAccountKey
    }

    /// What the cache says the key is, read once and kept.
    ///
    /// `@ObservationIgnored` because nothing draws it: it is an identifier, and
    /// every value derived from it is already published.
    @ObservationIgnored private var cachedAccountKey: String?

    // MARK: - Showing a window

    /// Draws `window` from the cache immediately, then refreshes it.
    ///
    /// Cache first and always: everything drawn comes from the store, so the
    /// calendar renders offline exactly as far back and forward as it was last
    /// refreshed, and a slow server delays an update rather than a screen.
    public func show(_ window: CalendarWindow) async {
        self.window = window
        await loadFromCache(window)
        await refresh(window)
    }

    /// Re-reads the visible window from the store without touching the network.
    /// Called after a write, and on returning to the screen.
    public func loadFromCache(_ window: CalendarWindow) async {
        do {
            if availability.accountID == nil, cachedAccountKey == nil {
                cachedAccountKey = try await store.storedAccountKey()
            }

            let occurrences = try await store.occurrences(in: window, accountKey: accountKey)
            let calendars = try await store.calendars(accountKey: accountKey ?? "")
            var series: [CalendarEventID: CalendarEventSnapshot] = [:]

            for id in Set(occurrences.map(\.seriesID)) {
                if let key = accountKey,
                    let snapshot = try await store.series(id: id, accountKey: key)
                {
                    series[id] = snapshot
                }
            }

            self.calendars = calendars
            seriesByID = series

            let byID = Dictionary(
                calendars.map { ($0.calendarID, $0) }, uniquingKeysWith: { first, _ in first })

            clusters = CalendarRowBuilder.clusters(
                occurrences: occurrences.filter { occurrence in
                    // Filtered **here**, never on the wire: the visibility a
                    // user set in a browser is a display preference, and the
                    // query has no condition for it anyway.
                    guard let id = occurrence.calendarID else { return true }

                    return locallyHidden.contains(id) == false
                },
                series: series,
                calendars: byID,
                defaultZone: zone()
            )
        } catch {
            logger.error("Calendar cache read failed: \(error, privacy: .public)")
        }
    }

    /// The series behind an occurrence, from the cache.
    ///
    /// **Always the series, never the tapped occurrence.** A detail screen —
    /// and, later, an editor — reads the recurrence and the description off
    /// this: a form seeded from one occurrence of a weekly standup would send
    /// that Tuesday as the series' start, and saving a corrected spelling would
    /// drag every other occurrence onto the week the user happened to be
    /// looking at.
    public func series(_ id: CalendarEventID) async -> CalendarEventSnapshot? {
        guard let accountKey else { return nil }

        return try? await store.series(id: id, accountKey: accountKey)
    }

    /// Hides or shows a calendar **on this device only**.
    public func setHidden(_ hidden: Bool, calendar id: CalendarID) async {
        if hidden { locallyHidden.insert(id) } else { locallyHidden.remove(id) }

        if let window { await loadFromCache(window) }
    }

    /// Whether a calendar is drawn, honouring the server's tick as the initial
    /// state and the local override afterwards.
    public func isShown(_ calendar: CalendarSnapshot) -> Bool {
        locallyHidden.contains(calendar.calendarID) == false && calendar.isVisible
    }

    // MARK: - Writing

    /// The calendars a new event may be put on, straight from `myRights`.
    ///
    /// Empty means the create affordance is **disabled with a reason**, never
    /// hidden: a control that vanishes teaches nothing, and "you can't add
    /// events to any calendar here" is the sentence that sends somebody to the
    /// web UI to fix their sharing.
    public var writableCalendars: [CalendarSnapshot] {
        calendars.filter(\.mayAddItems)
    }

    /// The calendar a row belongs to, for the rights a detail screen greys its
    /// buttons from.
    public func calendar(_ id: CalendarID?) -> CalendarSnapshot? {
        guard let id else { return nil }

        return calendars.first { $0.calendarID == id }
    }

    /// Creates an event, then re-runs the visible window.
    ///
    /// The re-query is not optional and not an optimisation: where a recurring
    /// series' occurrences land is a question only the server can answer, and
    /// expanding a rule on the device is the one thing this client may not do.
    public func create(_ draft: EventDraft) async -> CalendarWriteOutcome {
        await perform { writer, accountID, accountKey in
            await writer.create(draft, accountID: accountID, accountKey: accountKey)
        }
    }

    /// Changes a **series**. An occurrence id here is refused by name, which is
    /// why every screen passes `seriesID`.
    public func update(
        _ id: CalendarEventID,
        to draft: EventDraft
    ) async -> CalendarWriteOutcome {
        await perform { writer, accountID, accountKey in
            await writer.update(id, to: draft, accountID: accountID, accountKey: accountKey)
        }
    }

    /// Deletes a **series**, whole and unrecoverably.
    public func delete(_ id: CalendarEventID) async -> CalendarWriteOutcome {
        await perform { writer, accountID, accountKey in
            await writer.delete(id, accountID: accountID, accountKey: accountKey)
        }
    }

    /// Resolves the account, runs the write, and puts the screen back in step
    /// with the cache afterwards — **on both outcomes**, because a rollback has
    /// already happened by the time a refusal arrives and the screen is still
    /// drawing the optimistic version.
    private func perform(
        _ body: (CalendarWriter, AccountID, String) async -> CalendarWriteOutcome
    ) async -> CalendarWriteOutcome {
        guard let accountID = availability.accountID, let accountKey else {
            return .noCalendar
        }

        let writer = CalendarWriter(client: client, store: store)
        let outcome = await body(writer, accountID, accountKey)

        if let window {
            await loadFromCache(window)

            if outcome.didWrite { await refresh(window) }
        }

        return outcome
    }

    // MARK: - Refreshing

    /// Re-runs the window's queries. **Call this while somebody is looking and
    /// at no other time.**
    @discardableResult
    public func refresh(_ window: CalendarWindow) async -> CalendarRefresh {
        if let inFlight { return await inFlight.value }

        status = .refreshing

        let task = Task { [weak self] () -> CalendarRefresh in
            guard let self else { return .noCalendarAccount }

            return await self.perform(window)
        }

        inFlight = task
        let outcome = await task.value
        inFlight = nil

        switch outcome {
        case .refreshed(let summary):
            mayBeIncomplete = summary.mayBeIncomplete
            lastRefreshedAt = .now
            status = .idle
        default:
            status = .failed(outcome)
        }

        await loadFromCache(window)

        return outcome
    }

    private func perform(_ window: CalendarWindow) async -> CalendarRefresh {
        let session: Session

        do {
            session = try await client.session()
        } catch let error as JMAPError {
            // **The cache still answers for availability.** Without this a
            // launch with no network drew "This server does not have a
            // calendar" over a month of perfectly good cached events, because
            // `isAvailable` starts false and the only thing that ever raised it
            // was a session this branch has just failed to fetch. Seen on a
            // 13-inch iPad against an unreachable host: the empty state, with
            // the whole cache sitting behind it.
            await availability.refresh(session: nil)

            return .from(error)
        } catch {
            await availability.refresh(session: nil)

            return .rejected(reason: String(describing: error))
        }

        await availability.refresh(session: session)

        guard let accountID = session.calendarAccountID, let accountKey else {
            return .noCalendarAccount
        }

        // Clamped **before** the request. A window past the horizon is refused
        // whole with `cannotCalculateOccurrences`, not answered short, so
        // asking optimistically means getting nothing at all.
        let clamped = window.clamped(around: today())

        guard let asked = clamped.window else { return .beyondHorizon }

        var summary = CalendarRefreshSummary(mayBeIncomplete: clamped.mayBeIncomplete)
        let bounds = asked.fetchBounds(in: zone())
        let filter = CalendarEventFilter(after: bounds.after, before: bounds.before)
        let chunk = availability.maxEventsInGet

        do {
            // **One request** for the whole window: `Calendar/get`, the
            // collapsed query answering the series a form is edited through,
            // and the expanded query answering the occurrences a grid draws —
            // each back-referenced into its own get. Both are needed and they
            // travel together: an occurrence id cannot be written through, and
            // a series cannot be placed without expanding it.
            var builder = RequestBuilder(session: session)
            let calendarsCall = builder.add(CalendarGet(accountID: accountID))
            let seriesPage = add(
                query: &builder, accountID: accountID, filter: filter,
                position: 0, limit: chunk, expanded: false)
            let occurrencePage = add(
                query: &builder, accountID: accountID, filter: filter,
                position: 0, limit: chunk, expanded: true)

            let results = try await client.send(builder)
            summary.requests += 1

            let calendarResult = try results.result(of: calendarsCall)
            var seriesList = try results.result(of: seriesPage.get).list
            var occurrenceList = try results.result(of: occurrencePage.get).list

            let seriesTotal = try results.result(of: seriesPage.query).total ?? seriesList.count
            let occurrenceTotal =
                try results.result(of: occurrencePage.query).total ?? occurrenceList.count

            // Further pages of either while its reported `total` says there are
            // more, chunked by **`maxEventsInGet`** — 100, a fifth of core's
            // ceiling — and counted in *occurrences* on the expanded side.
            var seriesFetched = seriesList.count
            var occurrencesFetched = occurrenceList.count

            while seriesFetched < seriesTotal || occurrencesFetched < occurrenceTotal {
                var page = RequestBuilder(session: session)
                var seriesCall: QueryPair?
                var occurrenceCall: QueryPair?

                if seriesFetched < seriesTotal {
                    seriesCall = add(
                        query: &page, accountID: accountID, filter: filter,
                        position: seriesFetched, limit: chunk, expanded: false)
                }

                if occurrencesFetched < occurrenceTotal {
                    occurrenceCall = add(
                        query: &page, accountID: accountID, filter: filter,
                        position: occurrencesFetched, limit: chunk, expanded: true)
                }

                let pageResults = try await client.send(page)
                summary.requests += 1

                var progressed = false

                if let seriesCall {
                    let list = try pageResults.result(of: seriesCall.get).list
                    progressed = progressed || list.isEmpty == false
                    seriesFetched += max(
                        try pageResults.result(of: seriesCall.query).ids.count, list.count)
                    seriesList += list
                }

                if let occurrenceCall {
                    let list = try pageResults.result(of: occurrenceCall.get).list
                    progressed = progressed || list.isEmpty == false
                    occurrencesFetched += max(
                        try pageResults.result(of: occurrenceCall.query).ids.count, list.count)
                    occurrenceList += list
                }

                // A page that moved nothing means the server's `total`
                // disagrees with what it will hand over — a truncated answer,
                // or an occurrence excluded between the count and the page.
                // Stopping is the only way this loop is guaranteed to end.
                if progressed == false { break }
            }

            // One write per refresh, in the order the reads depend on:
            // calendars first so an occurrence can be placed against its
            // calendar's zone, then the series a form is edited through, then
            // the window's occurrences replaced wholesale.
            let stored = try await store.replaceCalendars(
                calendarResult.list, accountKey: accountKey)
            try await store.upsertSeries(seriesList, accountKey: accountKey)

            let zones = Dictionary(
                stored.compactMap { calendar in
                    calendar.timeZone.map { (calendar.calendarID.rawValue, $0) }
                },
                uniquingKeysWith: { first, _ in first })

            summary.series = seriesList.count
            summary.occurrences = try await store.replaceOccurrences(
                occurrenceList,
                in: asked,
                accountKey: accountKey,
                zone: zone(),
                calendarZones: zones
            )

            return .refreshed(summary)
        } catch let error as JMAPError {
            logger.error("Calendar refresh failed: \(String(describing: error), privacy: .public)")

            return .from(error)
        } catch {
            return .rejected(reason: String(describing: error))
        }
    }

    // MARK: - Consequences of a refresh that already happened

    /// System search over the events **already in the cache**.
    ///
    /// Built once per service rather than per pass: it owns a high-water record
    /// of what it has written, and rebuilding it would either lose that record
    /// or re-read it every time a window changed.
    ///
    /// `@ObservationIgnored` because `@Observable` rewrites every stored
    /// property into a computed one and `lazy` cannot survive that — the
    /// macro's own error says so. Nothing observes it anyway: it writes to
    /// CoreSpotlight and draws nothing.
    @ObservationIgnored private lazy var spotlight = CalendarSpotlightIndex(store: store)

    /// Puts what the cache holds into Spotlight.
    ///
    /// **Only after a refresh that actually wrote something.** Called on every
    /// window change it would be a local fetch over every cached occurrence
    /// each time somebody pressed Next, which is a cost paid for nothing: an
    /// index is a consequence of the cache having changed, and if it has not,
    /// there is nothing to say. It asks no server anything either way.
    public func indexForSpotlight() async {
        guard let accountKey else { return }

        await spotlight.refresh(accountKey: accountKey)
    }

    /// One occurrence, straight out of the cache.
    ///
    /// The resolution step every route in from outside the app makes before it
    /// draws anything: a Spotlight entry, a Handoff payload and a restored
    /// scene value all name an event that may have been cancelled since. Nil is
    /// the answer that lets the calendar say so.
    public func occurrence(
        _ id: CalendarEventID, accountKey: String
    ) async -> CalendarOccurrenceSnapshot? {
        try? await store.occurrence(id, accountKey: accountKey)
    }

    /// Claims a tapped Spotlight result if it is one of **this** index's, and
    /// posts it to ``CalendarIntentRouter``.
    ///
    /// **Returns whether it was ours**, because the shell has one Spotlight
    /// callback and two indexes behind it whose identifiers are the same shape.
    /// Answering false is what leaves a conversation to the mail branch;
    /// answering true wrongly would open the calendar on a message.
    ///
    /// Two questions, not one. The index's own record settles it when it is
    /// intact; when it has been lost — it lives in `UserDefaults`, which any
    /// reinstall clears — the id is resolved against the cache instead. Asking
    /// only the record would send an event tap down the mail branch after
    /// exactly the kind of wipe nobody notices.
    ///
    /// It posts rather than opens: nothing here knows whether the calendar is
    /// on screen, and the shell that does is the thing that consumes the
    /// request.
    public func openIndexedEvent(uid: String) async -> Bool {
        guard let ids = CalendarDeepLink.occurrence(forSpotlightUID: uid) else { return false }

        var isOurs = await spotlight.knows(uid)

        if isOurs == false {
            isOurs = await occurrence(ids.occurrenceID, accountKey: ids.accountKey) != nil
        }

        guard isOurs else { return false }

        CalendarIntentRouter.shared.request(
            .occurrence(accountKey: ids.accountKey, occurrenceID: ids.occurrenceID))

        return true
    }

    /// Forgets every indexed event, for sign-out.
    ///
    /// The correctness requirement: entries left behind leak the previous
    /// account's calendar into system search on a device somebody else may now
    /// be holding.
    public func forgetIndexedEvents() async {
        await spotlight.removeEverything()
        SharedCalendarStore.clear()
    }

    /// Hands the widget today's remaining events.
    ///
    /// The words are passed in because the catalogue lives in `PLMailUI` and
    /// this is `PLMailCore`; a literal here would put an English "All day" on a
    /// German home screen. Writing shared state is a **consequence** of a
    /// refresh, never a reason for one — the calendar has no push and no
    /// delta, so nothing could update this in the background even if it were
    /// allowed to.
    public func publishWidgetState(allDayWord: String, locale: Locale) {
        let today = today()
        let events = CalendarWidgetPlan.upcoming(
            in: clusters,
            today: today,
            now: .now,
            timeText: { cluster in
                EventSpeech.timeSpan(cluster, locale: locale, allDayWord: allDayWord)
            })

        SharedCalendarStore.write(
            SharedCalendarState(
                upcoming: events,
                dayKey: today.key,
                hasCalendar: availability.isAvailable))
    }

    /// A query and the get back-referenced into it, which is the only pairing
    /// that makes expansion usable: ids the getter refused would leave the
    /// feature a list of strings nothing accepts.
    private struct QueryPair {
        let query: CallHandle<CalendarEventQuery>
        let get: CallHandle<CalendarEventGet>
    }

    private func add(
        query builder: inout RequestBuilder,
        accountID: AccountID,
        filter: CalendarEventFilter,
        position: Int,
        limit: Int,
        expanded: Bool
    ) -> QueryPair {
        let query = builder.add(
            CalendarEventQuery(
                accountID: accountID,
                filter: filter,
                position: position,
                // Asked for at the **get's** ceiling rather than the query's
                // 500, because the get is what the ids are handed to and 500 of
                // them is `requestTooLarge`.
                limit: limit,
                expandRecurrences: expanded
            ))

        let get = builder.add(
            CalendarEventGet(
                accountID: accountID,
                ids: .reference(query.reference(path: "/ids")),
                properties: expanded
                    ? CalendarStore.occurrenceProperties : Self.seriesProperties
            ))

        return QueryPair(query: query, get: get)
    }

    /// What a series row needs to be drawn, listed and edited.
    ///
    /// Deliberately without `recurrenceRules` and `recurrenceOverrides`: the
    /// cache stores *whether* a series recurs, never the rule, so that no
    /// editor can be tempted to rebuild one from a dropdown and flatten an
    /// elaborate imported rule because somebody corrected a typo. An editor
    /// that means to touch recurrence fetches the whole body first.
    static let seriesProperties = [
        "id", "uid", "calendarId", "title", "description", "start", "duration", "timeZone",
        "showWithoutTime", "locations", "status", "privacy", "isRecurring", "kind", "source",
        "sequence", "created", "updated",
    ]
}

extension CalendarService {
    /// Builds the whole calendar stack from what a mail screen already holds.
    ///
    /// Exists so that adopting the feature is one `@State` and one row rather
    /// than four constructions in a file six other people are editing. The
    /// store is a second `@ModelActor` over `SyncStore`'s **own container**, so
    /// there is one SQLite file, one propagation path to the main context, and
    /// no second copy of anything.
    ///
    /// Availability starts false and stays false until this is refreshed — the
    /// row it gates is either there or not, and a probe that has to time out
    /// must not be what holds the answer.
    public static func make(
        client: JMAPClient,
        store: SyncStore,
        serverID: String
    ) -> CalendarService {
        let calendarStore = CalendarStore(modelContainer: store.modelContainer)

        return CalendarService(
            client: client,
            store: calendarStore,
            serverID: serverID,
            availability: CalendarAvailability(store: calendarStore)
        )
    }

    /// Re-probes availability **on a change in the world, never on a timer**.
    ///
    /// Call it when the screen appears and when the connection or the account
    /// list changes. The session fetch is single-flighted inside `JMAPClient`,
    /// so this costs nothing when one has already been read.
    public func probeAvailability() async {
        await availability.refresh(session: try? await client.session())
    }
}
