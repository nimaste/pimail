import Foundation
import Testing

@testable import JMAPKit

/// Every fixture here was captured verbatim from a running plMail server and
/// is shared with the Android client, so a shape that decodes here is a shape
/// that exists — which is the whole point of this phase. Nothing in the
/// calendar layer has a UI yet; these tests are what the UI will be allowed to
/// assume.
@Suite("Calendar wire decoding")
struct CalendarDecodingTests {

    // MARK: - Session

    /// The client rule for finding the calendar account is "the single account
    /// whose `accountCapabilities` carry the calendars URN". `primaryAccounts`
    /// may well carry it too, but `accountCapabilities` is what the methods
    /// themselves check against, so it is the reading that cannot disagree with
    /// them.
    @Test("exactly one account advertises calendars, and it is not every account")
    func calendarAccountDiscovery() throws {
        let session: [String: JSONValue] = try Fixture.decode("session-calendars")
        let accounts = try #require(session["accounts"]?.objectValue)

        let calendarAccounts = accounts.filter { _, account in
            account.objectValue?["accountCapabilities"]?
                .objectValue?[Capability.calendars.rawValue] != nil
        }

        #expect(accounts.count == 2)
        #expect(calendarAccounts.keys.sorted() == ["1"])

        // The top-level capability is an empty object: its *presence* is the
        // "this instance has calendars" signal, so a client testing its
        // contents would decide a server with calendars has none.
        #expect(
            session["capabilities"]?.objectValue?[Capability.calendars.rawValue] == .object([:]))
    }

    /// Three numbers a client would otherwise learn the hard way. `maxEventsInGet`
    /// is a *fifth* of core's `maxObjectsInGet`, and `materialisedHorizon` is a
    /// pair of opaque PHP relative-date expressions to display and never parse.
    @Test("the account capability publishes the get ceiling and the horizon")
    func calendarAccountCapability() throws {
        let session: [String: JSONValue] = try Fixture.decode("session-calendars")
        let capability = try #require(
            session["accounts"]?.objectValue?["1"]?
                .objectValue?["accountCapabilities"]?
                .objectValue?[Capability.calendars.rawValue]?.objectValue
        )

        #expect(capability["maxEventsInGet"] == .int(CalendarEventGet.maxEventsInGet))
        #expect(capability["maxEventsInGet"] == .int(100))
        #expect(capability["maxEventsInSet"] == .int(500))
        #expect(capability["mayCreateCalendar"] == .bool(false))
        #expect(
            capability["materialisedHorizon"]
                == .object(["past": .string("-1 year"), "future": .string("+2 years")]))
    }

    /// The Session object itself still decodes with calendars advertised — a
    /// server that grew a capability must not break a client that has not
    /// modelled it.
    @Test("a session advertising calendars still decodes as a Session")
    func sessionStillDecodes() throws {
        let session = try Fixture.decode("session-calendars", as: Session.self)

        #expect(session.username == "e2e@plmail.test")
        #expect(session.accounts.count == 2)
        #expect(session.primaryMailAccountID == AccountID("1"))
    }

    // MARK: - Calendar/get

    @Test("Calendar/get decodes the whole list, its rights and its hex colour")
    func calendarGet() throws {
        let result = try calendars(from: "calendar-get")

        #expect(result.state == CalendarEventSet.fixedState)
        #expect(result.notFound.isEmpty)
        #expect(result.list.count == 3)

        let personal = result.list[0]

        #expect(personal.id == CalendarID("10542"))
        #expect(personal.name == "Personal")
        // `#rrggbb`, not the Tailwind token a Mailbox carries.
        #expect(personal.color == "#2563eb")
        #expect(personal.isDefault == true)
        #expect(personal.isVisible == true)
        #expect(personal.timeZone == "Europe/Berlin")
        #expect(personal.role == .default)
        #expect(personal.isSynced == false)

        // The four write gates agree because they are one gate server-side;
        // mayDelete is about the calendar and is false even on the default one.
        #expect(personal.myRights?.mayAddItems == true)
        #expect(personal.myRights?.mayUpdateAll == true)
        #expect(personal.myRights?.mayRemoveItems == true)
        #expect(personal.myRights?.mayDelete == false)

        #expect(result.list[1].role == .account)
    }

    /// The default is read off `isDefault`, not off `role == "default"`: the
    /// role vocabulary is open, and a second role meaning the same thing would
    /// silently take over.
    @Test("the default and writable calendars come from the flags, not the role")
    func calendarHelpers() throws {
        let result = try calendars(from: "calendar-get")

        #expect(result.defaultCalendar?.id == CalendarID("10542"))
        #expect(result.writableCalendars.count == 3)
    }

    /// An unrecognised role degrades rather than failing the whole `Calendar/get`
    /// it arrived in — a client that crashed on a role added next release would
    /// lose every calendar, not one.
    @Test("an unknown calendar role decodes as unknown rather than failing")
    func openRoleVocabulary() {
        #expect(CalendarRole(rawValue: "shared") == .other("shared"))
        #expect(CalendarRole(rawValue: "remote") == .remote)
    }

    // MARK: - CalendarEvent/query, collapsed

    @Test("a collapsed query answers one id per series, with no delta path")
    func collapsedQuery() throws {
        let results = try results(from: "event-query-get")
        let query = try results.result(
            of: CallHandle<CalendarEventQuery>(callID: CallID(rawValue: "q0")))

        #expect(query.queryState == CalendarEventSet.fixedState)
        // There is no CalendarEvent/queryChanges; a list is refreshed by
        // re-running the query and by nothing else.
        #expect(query.canCalculateChanges == false)
        #expect(query.position == 0)
        #expect(query.total == 4)
        #expect(query.limit == 500)
        #expect(
            query.ids == [
                CalendarEventID("10867"), CalendarEventID("10865"),
                CalendarEventID("10868"), CalendarEventID("10866"),
            ])

        // Collapsed, every id is a plain series id — nothing carries the
        // occurrence spelling.
        #expect(query.ids.allSatisfy { $0.rawValue.contains("_") == false })
    }

    @Test("a series decodes with its local start, its UTC stamps and its rule")
    func collapsedSeries() throws {
        let standup = try #require(try events(from: "event-query-get").first)

        #expect(standup.id == CalendarEventID("10867"))
        #expect(standup.uid == "df7a06897f850359167280505e68e0ef@plmail")
        #expect(standup.type == "Event")
        #expect(standup.calendarID == CalendarID("10542"))
        #expect(standup.title == "Team-Standup")
        #expect(standup.duration == "PT15M")
        #expect(standup.timeZone == "Europe/Berlin")
        #expect(standup.status == .confirmed)
        #expect(standup.privacy == .public)
        #expect(standup.sequence == 0)
        #expect(standup.source == .manual)

        // kind is null, which is the server's own isExtracted() test: a person
        // made this one.
        #expect(standup.kind == nil)
        #expect(standup.isExtracted == false)

        // A local wall clock with no offset and no Z...
        #expect(standup.start == LocalDateTime(rawValue: "2026-08-03T10:00:00"))
        // ...beside two Z-suffixed instants. Different types, on one object.
        #expect(standup.created?.date == UTCDate.parse("2026-08-05T21:10:21Z"))
        #expect(standup.created == standup.updated)

        let rule = try #require(standup.recurrenceRules?.first)

        #expect(standup.recurrenceRules?.count == 1)
        #expect(rule.frequency == "weekly")
        // Lower case, not the upper-case iCalendar spelling.
        #expect(rule.byDay?.map(\.day) == ["mo", "we", "fr"])
    }

    /// `isRecurring` is derived server-side and is a different claim from
    /// "carries a rule". Reading the rule instead is wrong exactly on the
    /// imported events a user is most likely to notice.
    @Test("isRecurring is read, never inferred from recurrenceRules")
    func isRecurringIsDerived() throws {
        let list = try events(from: "event-query-get")

        #expect(list[0].isRecurring == true)
        #expect(list[0].recurrenceRules?.isEmpty == false)

        // The dentist has no rule and does not recur — the two agree here, and
        // this pins that the client reads the published flag either way.
        #expect(list[1].isRecurring == false)
        #expect(list[1].recurrenceRules == nil)
    }

    @Test("an all-day event carries showWithoutTime and no zone at all")
    func allDayEvent() throws {
        let sommerfest = try #require(try events(from: "event-query-get").last)

        #expect(sommerfest.title == "Sommerfest")
        #expect(sommerfest.showWithoutTime == true)
        #expect(sommerfest.duration == "P1D")
        // Absent, not "UTC" and not the device's — an all-day event is
        // floating, and zoning it makes it move when the user travels.
        #expect(sommerfest.timeZone == nil)
        #expect(sommerfest.start == LocalDateTime(rawValue: "2026-08-08T00:00:00"))
    }

    /// A place is stored as a **label**, under a key the server chose and which
    /// nothing may read.
    @Test("a location decodes as one named label under an opaque key")
    func location() throws {
        let dentist = try events(from: "event-query-get")[1]

        #expect(dentist.locations?.count == 1)
        #expect(dentist.locationName == "Praxis Dr. Weber")
        #expect(dentist.locations?["1"]?.type == "Location")
        #expect(dentist.description == "Kontrolle")
        #expect(dentist.status == .confirmed)
        #expect(try events(from: "event-query-get")[2].status == .tentative)
    }

    // MARK: - CalendarEvent/query, expanded

    @Test("an expanded query answers one id per occurrence, in instance order")
    func expandedQuery() throws {
        let results = try results(from: "event-query-get-expanded")
        let query = try results.result(
            of: CallHandle<CalendarEventQuery>(callID: CallID(rawValue: "q0")))

        #expect(query.total == 5)
        #expect(
            query.ids == [
                CalendarEventID("10867_20260803T080000Z"),
                CalendarEventID("10867_20260805T080000Z"),
                CalendarEventID("10865"),
                CalendarEventID("10867_20260807T080000Z"),
                CalendarEventID("10866"),
            ])

        // A one-off keeps its plain series id even in an expanded answer: its
        // single occurrence *is* the event, and the plain id is the one
        // CalendarEvent/set accepts back.
        #expect(query.ids[2].rawValue.contains("_") == false)
    }

    /// The named guarantee: an occurrence's parent is read from `seriesId` and
    /// **never** by splitting the id. The separator is plMail's own choice, the
    /// timestamp is the original start rather than the moved one, and a client
    /// that reassembled its own would be expanding recurrence rules by hand
    /// through the back door.
    @Test("an occurrence's parent is read from seriesId, never parsed out of the id")
    func occurrenceParentComesFromSeriesID() throws {
        let list = try events(from: "event-query-get-expanded")
        let occurrences = list.filter(\.isOccurrence)

        #expect(occurrences.count == 3)

        for occurrence in occurrences {
            #expect(occurrence.seriesID == CalendarEventID("10867"))
            #expect(occurrence.writableID == CalendarEventID("10867"))
            // The id the query handed back is not the id a write goes to.
            #expect(occurrence.writableID != occurrence.id)
        }

        // A one-off is not an occurrence, and its writable id is its own.
        let oneOff = try #require(list.first { $0.id == CalendarEventID("10866") })

        #expect(oneOff.isOccurrence == false)
        #expect(oneOff.seriesID == nil)
        #expect(oneOff.writableID == oneOff.id)
    }

    /// A moved instance is drawn at its new time and still **named** by its
    /// old. File a `recurrenceOverrides` patch under `start` instead of
    /// `recurrenceId` and the server records an exception for an occurrence
    /// that was never there, leaving the real one still drawn.
    @Test("a moved occurrence's recurrenceId is its original start, not its actual one")
    func movedOccurrenceKeepsItsOriginalRecurrenceID() throws {
        let list = try events(from: "event-query-get-expanded")
        let moved = try #require(
            list.first { $0.id == CalendarEventID("10867_20260807T080000Z") })

        #expect(moved.title == "Standup (Retro-Woche)")
        #expect(moved.start == LocalDateTime(rawValue: "2026-08-07T11:00:00"))
        #expect(moved.recurrenceID == LocalDateTime(rawValue: "2026-08-07T10:00:00"))
        #expect(moved.start != moved.recurrenceID)

        // The zone the recurrenceId is read in — UTC for a floating series,
        // which is why it is published separately rather than assumed to be
        // the event's own.
        #expect(moved.recurrenceIDTimeZone == "Europe/Berlin")

        // An unmoved instance has the two agreeing, which is what makes the
        // moved case easy to miss without a test.
        let unmoved = try #require(
            list.first { $0.id == CalendarEventID("10867_20260803T080000Z") })

        #expect(unmoved.start == unmoved.recurrenceID)
    }

    /// The draft says an instance MUST NOT carry the series' rules. A client
    /// that read them off an occurrence would expand a series once per
    /// occurrence of it.
    @Test("an occurrence nulls the series' recurrence rules and overrides")
    func occurrenceNullsRecurrence() throws {
        let occurrence = try #require(
            try events(from: "event-query-get-expanded").first { $0.isOccurrence })

        #expect(occurrence.recurrenceRules == nil)
        #expect(occurrence.recurrenceOverrides == nil)
        // isRecurring is still true: it describes the series this came from.
        #expect(occurrence.isRecurring == true)
    }

    /// An expanded window past the account's `materialisedHorizon` is refused,
    /// because the expanded answer *is* the list of occurrences — a series that
    /// stops at the horizon would come back as a series that ends.
    @Test("an over-horizon expansion arrives as a typed cannotCalculateOccurrences")
    func cannotCalculateOccurrences() throws {
        let results = try results(from: "event-query-get-expanded")
        let handle = CallHandle<CalendarEventQuery>(callID: CallID(rawValue: "beyond"))
        let failure = try #require(results.failure(of: handle))

        guard case .methodFailed(let type, _, let callID) = failure else {
            Issue.record("Expected a method error, got \(failure)")
            return
        }

        #expect(type == .cannotCalculateOccurrences)
        #expect(type == .other("cannotCalculateOccurrences"))
        #expect(callID == CallID(rawValue: "beyond"))
        // Not a resync instruction and not a client bug — it is a window to
        // clamp, so neither flag may claim it.
        #expect(failure.requiresResync == false)
        #expect(failure.isRetryable == false)
    }

    // MARK: - recurrenceOverrides

    /// The map is keyed by each occurrence's **original** start and its values
    /// are arbitrary patches — decoded as raw JSON, because a fixed shape would
    /// silently drop whatever this version has not heard of, and the loss would
    /// only show when the map was written back, which replaces it whole.
    @Test("recurrenceOverrides decode keyed by LocalDateTime, values left as raw JSON")
    func recurrenceOverrides() throws {
        let results = try results(from: "event-overrides")
        let series = try #require(
            try results.result(of: CallHandle<CalendarEventGet>(callID: CallID(rawValue: "g1")))
                .list.first)

        let key = try #require(LocalDateTime(rawValue: "2026-08-07T10:00:00"))
        let override = try #require(series.recurrenceOverrides?[key])

        #expect(series.recurrenceOverrides?.count == 1)
        #expect(
            override
                == .object([
                    "title": .string("Standup (Retro-Woche)"),
                    "start": .string("2026-08-07T11:00:00"),
                ]))

        // The key is where the occurrence *was*; the start inside is where it
        // went. Confusing the two is how an exception lands on nothing.
        #expect(key.rawValue != override.objectValue?["start"]?.stringValue)
    }

    @Test("a successful update reports its key and a null value")
    func updateReportsNull() throws {
        let results = try results(from: "event-overrides")
        let set = try results.result(
            of: CallHandle<CalendarEventSet>(callID: CallID(rawValue: "ov")))

        #expect(set.oldState == CalendarEventSet.fixedState)
        #expect(set.newState == CalendarEventSet.fixedState)
        #expect(set.updated?[CalendarEventID("10867")] == JSONValue.null)
        #expect(set.hasFailures == false)
        // `{}` when empty, never `[]` — an array here would fail to decode
        // rather than quietly producing nothing.
        #expect(set.created?.isEmpty == true)
        #expect(set.notCreated?.isEmpty == true)
    }

    // MARK: - CalendarEvent/set results

    @Test("a create reports the id, the uid and the derived isRecurring")
    func createResult() throws {
        let results = try results(from: "event-set-create")
        let set = try results.result(
            of: CallHandle<CalendarEventSet>(callID: CallID(rawValue: "s0")))
        let created = try #require(set.created)

        #expect(created.count == 4)
        #expect(created["e1"]?.id == CalendarEventID("10865"))
        #expect(created["e1"]?.uid == "a2b69d2799e0d4e3bbcf91cf88f18bb1@plmail")
        #expect(created["e1"]?.calendarID == CalendarID("10542"))
        #expect(created["e1"]?.isRecurring == false)
        #expect(created["e1"]?.sequence == 0)

        // Derived server-side: a create carrying a rule the server cannot
        // convert comes back false, so this is the answer rather than an echo.
        #expect(created["e3"]?.isRecurring == true)
        #expect(created["e4"]?.calendarID == CalendarID("10543"))
        #expect(set.hasFailures == false)
    }

    /// §1.7's refusals, decoded into something a caller can act on: the type
    /// says what to do, and `properties` says which field to point at.
    @Test("a refused create names the properties it refused")
    func invalidPropertiesNamesOffenders() throws {
        let results = try results(from: "event-errors-update-destroy")
        let set = try results.result(
            of: CallHandle<CalendarEventSet>(callID: CallID(rawValue: "bad-props")))
        let error = try #require(set.notCreated?["bad"])

        #expect(set.hasFailures)
        #expect(error.type == .invalidProperties)
        #expect(error.invalidProperties == ["participants", "alerts"])
        #expect(error.isReadOnlyCalendar == false)
        #expect(set.firstFailure == error)
    }

    /// A `Z` on a start is refused rather than guessed at — "it says UTC, the
    /// zone beside it says Europe/Berlin, and guessing which the client meant
    /// moves a meeting by hours in silence".
    @Test("an instant sent as a start is refused, naming start")
    func invalidStartIsRefused() throws {
        let results = try results(from: "event-errors-update-destroy")
        let set = try results.result(
            of: CallHandle<CalendarEventSet>(callID: CallID(rawValue: "bad-start")))
        let error = try #require(set.notCreated?["badz"])

        #expect(error.type == .invalidProperties)
        #expect(error.invalidProperties == ["start"])
        #expect(error.description?.contains("LocalDateTime") == true)
    }

    /// **Not `notFound`.** This server minted the occurrence id, and a client
    /// told "no such event" would go looking for a bug in its own id handling
    /// rather than at `seriesId`.
    @Test("an occurrence id in an update is refused by name, pointing at seriesId")
    func occurrenceIDInUpdateIsRefusedByName() throws {
        let results = try results(from: "event-query-get-expanded")
        let set = try results.result(
            of: CallHandle<CalendarEventSet>(callID: CallID(rawValue: "instance-set")))
        let error = try #require(set.notUpdated?[CalendarEventID("10867_20260807T080000Z")])

        #expect(error.type == .invalidArguments)
        #expect(error.type != .notFound)
        #expect(error.description?.contains("seriesId") == true)
        #expect(error.description?.contains("recurrenceOverrides") == true)
    }

    @Test("method-level refusals arrive as typed method errors")
    func methodLevelRefusals() throws {
        let results = try results(from: "event-errors-update-destroy")

        let cases: [(CallID, MethodErrorType)] = [
            (CallID(rawValue: "bad-window"), .invalidArguments),
            (CallID(rawValue: "bad-sort"), .unsupportedSort),
            (CallID(rawValue: "bad-account"), .accountNotSupportedByMethod),
        ]

        for (callID, expected) in cases {
            let failure = try #require(
                results.failure(of: CallHandle<CalendarEventQuery>(callID: callID)))

            guard case .methodFailed(let type, _, _) = failure else {
                Issue.record("Expected a method error for \(callID), got \(failure)")
                continue
            }

            #expect(type == expected)
        }
    }

    @Test("a destroy reports its ids, and a missing event is notFound rather than an error")
    func destroyAndNotFound() throws {
        let results = try results(from: "event-errors-update-destroy")
        let set = try results.result(
            of: CallHandle<CalendarEventSet>(callID: CallID(rawValue: "upd")))

        #expect(set.destroyed == [CalendarEventID("10868")])
        #expect(set.updated?[CalendarEventID("10865")] == JSONValue.null)
        #expect(set.hasFailures == false)

        let get = try results.result(
            of: CallHandle<CalendarEventGet>(callID: CallID(rawValue: "g-notfound")))

        // A foreign or missing event is notFound, never an error: "there is no
        // event 99999 for you" and "it is somebody else's" are one sentence.
        #expect(get.notFound == ["99999"])
        #expect(get.list.count == 1)
    }

    /// `CalendarEvent/get` returns `list` in repository order, and a query
    /// paired with a get renders in whatever `list` says.
    @Test("a get can be re-ordered back onto the ids the query asked for")
    func orderedByQueryIDs() throws {
        let results = try results(from: "event-query-get")
        let query = try results.result(
            of: CallHandle<CalendarEventQuery>(callID: CallID(rawValue: "q0")))
        let get = try results.result(
            of: CallHandle<CalendarEventGet>(callID: CallID(rawValue: "g0")))

        #expect(get.ordered(by: query.ids).map(\.id) == query.ids)
        // An id the get did not answer is dropped rather than crashing.
        #expect(get.ordered(by: [CalendarEventID("99999")]).isEmpty)
    }

    // MARK: - Helpers

    private func results(from fixture: String) throws -> MethodResults {
        try MethodResults.decode(body: Fixture.data(fixture), statusCode: 200)
    }

    private func calendars(from fixture: String) throws -> GetResult<JMAPCalendar> {
        try results(from: fixture).result(
            of: CallHandle<CalendarGet>(callID: CallID(rawValue: "c0")))
    }

    private func events(from fixture: String) throws -> [CalendarEvent] {
        try results(from: fixture).result(
            of: CallHandle<CalendarEventGet>(callID: CallID(rawValue: "g0"))
        ).list
    }
}
