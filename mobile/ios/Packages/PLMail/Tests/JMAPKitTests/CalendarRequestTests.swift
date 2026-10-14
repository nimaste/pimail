import Foundation
import Testing

@testable import JMAPKit

/// What this client *sends*. Every refusal in §1.7 that a type can make
/// unrepresentable is cheaper here than as an `invalidProperties` arriving
/// after somebody has typed a whole event, so these tests pin the shapes rather
/// than the errors.
@Suite("Calendar request encoding")
struct CalendarRequestTests {
    private let account = AccountID("1")
    private let calendar = CalendarID("10542")

    // MARK: - Capability

    /// A wrong URN in `using` makes the server refuse the **entire** request
    /// with `unknownCapability`, so this is not a detail: all four methods must
    /// name the vendor URN, and it must be one the request may declare.
    @Test("every calendar method declares the vendor calendars URN")
    func capability() {
        #expect(CalendarGet.capability == .calendars)
        #expect(CalendarEventQuery.capability == .calendars)
        #expect(CalendarEventGet.capability == .calendars)
        #expect(CalendarEventSet.capability == .calendars)

        #expect(Capability.calendars.rawValue == "urn:plmail:params:jmap:calendars")
        // Deliberately not the IETF draft's URN, which names an unratified
        // contract no client could rely on.
        #expect(Capability.calendars.rawValue != "urn:ietf:params:jmap:calendars")
        #expect(Capability.calendars.isSupportedInUsing)
    }

    @Test("a calendar request declares core and calendars, and nothing else")
    func usingIsUnioned() throws {
        var builder = RequestBuilder()
        builder.add(CalendarGet(accountID: account))
        builder.add(CalendarEventQuery(accountID: account, filter: try window()))

        #expect(
            builder.makeRequest().using
                == ["urn:ietf:params:jmap:core", "urn:plmail:params:jmap:calendars"])
    }

    // MARK: - Calendar/get

    /// `null` and an omitted key are different requests: only the explicit null
    /// says "all of them".
    @Test("Calendar/get sends an explicit null for every calendar")
    func calendarGetSendsNullIDs() throws {
        #expect(
            try encode(CalendarGet(accountID: account))
                == #"{"accountId":"1","ids":null}"#)

        #expect(
            try encode(CalendarGet(accountID: account, ids: [calendar]))
                == #"{"accountId":"1","ids":["10542"]}"#)
    }

    // MARK: - CalendarEvent/query

    /// **Omitted, not `false`.** The two behave identically, so sending the
    /// argument only when it is wanted keeps a collapsed query byte-for-byte
    /// what an instance predating the feature has always been asked — which is
    /// what lets this client talk to a server that never heard of it.
    @Test("expandRecurrences is omitted when false and present when true")
    func expandRecurrencesIsOmittedWhenFalse() throws {
        let collapsed = try encode(CalendarEventQuery(accountID: account, filter: try window()))

        #expect(collapsed.contains("expandRecurrences") == false)
        #expect(
            collapsed
                == #"{"accountId":"1","filter":{"after":"2026-08-01T00:00:00Z","#
                + #""before":"2026-09-01T00:00:00Z"},"position":0}"#)

        let expanded = try encode(
            CalendarEventQuery(accountID: account, filter: try window(), expandRecurrences: true))

        #expect(expanded.contains(#""expandRecurrences":true"#))
    }

    /// **The window is UTC on the wire.** The server parses both ends with
    /// `new DateTimeImmutable($value)` and converts to UTC, so a naive local
    /// spelling is read in the *server's* default zone — and a client that
    /// built its window from local midnights and dropped the `Z` asks for a
    /// window offset by the difference between two machines, which sweeps
    /// freshly created events straight back out of a cache. ``UTCDate`` cannot
    /// encode any other spelling.
    @Test("the query window is always Z-suffixed UTC, never a naive local time")
    func windowIsUTC() throws {
        // A local midnight in Berlin is 22:00Z the day before. Whichever the
        // caller meant, what goes on the wire says which.
        let berlin = try #require(TimeZone(identifier: "Europe/Berlin"))
        let midnight = try #require(
            LocalDateTime(rawValue: "2026-08-01T00:00:00")?.date(in: berlin))

        let filter = CalendarEventFilter(
            after: midnight, before: midnight.addingTimeInterval(86400))
        let json = try string(filter)

        #expect(json.contains(#""after":"2026-07-31T22:00:00Z""#))
        #expect(json.hasSuffix("Z\"}"))
        // No naive spelling can survive the type.
        #expect(json.contains("2026-08-01T00:00:00\"") == false)
    }

    @Test("inCalendar is omitted rather than sent as null when filtering none")
    func inCalendarOmitted() throws {
        #expect(try string(try window()).contains("inCalendar") == false)
        #expect(try string(try window(inCalendar: calendar)).contains(#""inCalendar":"10542""#))
    }

    // MARK: - CalendarEvent/get

    /// The pairing that makes a month one round trip: an occurrence id is
    /// opaque and is handed straight back, never split.
    @Test("CalendarEvent/get takes the query's ids by back-reference under #ids")
    func backReference() throws {
        var builder = RequestBuilder()
        let query = builder.add(CalendarEventQuery(accountID: account, filter: try window()))

        builder.add(
            CalendarEventGet(
                accountID: account,
                ids: .reference(query.reference(path: "/ids")),
                properties: CalendarEventGet.occurrenceProperties
            ))

        let json = try String(decoding: builder.encoded(), as: UTF8.self)

        #expect(
            json.contains(
                ##""#ids":{"name":"CalendarEvent/query","path":"/ids","resultOf":"c0"}"##))
        #expect(json.contains(##""ids":"##) == false)
    }

    /// `seriesId` earns its place in the occurrence property list twice over:
    /// it is the row an occurrence hangs off, and the only id
    /// `CalendarEvent/set` accepts back.
    @Test("the occurrence property list asks for seriesId and recurrenceId")
    func occurrenceProperties() {
        #expect(CalendarEventGet.occurrenceProperties.contains("seriesId"))
        #expect(CalendarEventGet.occurrenceProperties.contains("recurrenceId"))
        // Not the fields a series row already holds — a month of occurrences
        // would carry each description once per instance.
        #expect(CalendarEventGet.occurrenceProperties.contains("description") == false)
        #expect(CalendarEventGet.maxEventsInGet == 100)
    }

    // MARK: - CalendarEvent/set, creating

    @Test("a create sends @type, the calendar, a local start and a default status")
    func createShape() throws {
        let event = NewCalendarEvent(
            calendarID: calendar,
            title: "Standup",
            start: try localTime("2026-08-03T09:00:00"),
            duration: "PT15M"
        )

        #expect(
            try string(event)
                == #"{"@type":"Event","calendarId":"10542","duration":"PT15M","#
                + #""start":"2026-08-03T09:00:00","status":"confirmed","title":"Standup"}"#)
    }

    /// On a create, `false` and absent mean the same thing, and an omitted key
    /// cannot be mistaken for a client trying to clear something.
    @Test("showWithoutTime, locations and recurrence are omitted when unset")
    func createOmitsUnset() throws {
        let plain = try string(
            NewCalendarEvent(
                calendarID: calendar, title: "T", start: try localTime("2026-08-03T09:00:00")))

        for absent in ["showWithoutTime", "locations", "recurrenceRules", "timeZone", "uid"] {
            #expect(plain.contains(absent) == false)
        }
    }

    /// A place is one label, not a list and not a structure: more than one
    /// entry is `invalidProperties`, and so is any key but `@type` and `name`.
    @Test("a location is sent as one keyed label carrying only @type and name")
    func locationShape() throws {
        let event = NewCalendarEvent(
            calendarID: calendar,
            title: "Zahnarzt",
            start: try localTime("2026-08-06T09:30:00"),
            location: "Praxis Dr. Weber"
        )

        #expect(
            try string(event)
                .contains(#""locations":{"1":{"@type":"Location","name":"Praxis Dr. Weber"}}"#))
    }

    /// At most one rule, and lower-case day codes — a rule spelled `MO` simply
    /// never fires on a Monday.
    @Test("a recurrence rule is sent as a one-element array with @type and lower-case days")
    func recurrenceRuleShape() throws {
        let event = NewCalendarEvent(
            calendarID: calendar,
            title: "Standup",
            start: try localTime("2026-08-03T09:00:00"),
            recurrenceRule: RecurrenceRule(frequency: "weekly", byDay: [NDay(day: "mo")])
        )

        #expect(
            try string(event)
                .contains(
                    #""recurrenceRules":[{"@type":"RecurrenceRule","#
                        + #""byDay":[{"@type":"NDay","day":"mo"}],"frequency":"weekly"}]"#))
    }

    // MARK: - The three-state timezone

    /// Omitted, JSON null and a name are **three different events**, and
    /// reading `?? null` collapses the first two — which quietly zones every
    /// floating event a client sends, on exactly the events (all-day,
    /// birthdays) where nobody thinks to look.
    @Test("an omitted, a floating and a zoned timezone each encode to their own JSON")
    func threeStateTimeZone() throws {
        func create(_ zone: EventTimeZone?) throws -> String {
            try string(
                NewCalendarEvent(
                    calendarID: calendar,
                    title: "T",
                    start: try localTime("2026-08-03T09:00:00"),
                    timeZone: zone
                ))
        }

        // Omitted — "you decide", and the calendar's own zone is used.
        #expect(try create(nil).contains("timeZone") == false)
        // JSON null — JSCalendar floating time. This is what an all-day event is.
        #expect(try create(.floating).contains(#""timeZone":null"#))
        // A name — that zone.
        #expect(try create(.zone("Europe/Berlin")).contains(#""timeZone":"Europe/Berlin""#))
    }

    @Test("a patch reaches all three timezone states too")
    func patchTimeZone() throws {
        var floating = CalendarEventPatch()
        floating.setTimeZone(.floating)

        var zoned = CalendarEventPatch()
        zoned.setTimeZone(.zone("Europe/Berlin"))

        let untouched = CalendarEventPatch()

        #expect(try string(floating) == #"{"timeZone":null}"#)
        #expect(try string(zoned) == #"{"timeZone":"Europe/Berlin"}"#)
        // An unnamed property means "leave it alone", which is the only
        // spelling for inheriting on a patch.
        #expect(untouched.isEmpty)
        #expect(try string(untouched) == "{}")
    }

    // MARK: - CalendarEvent/set, patching

    /// A key containing `/` is a JSON-pointer path, refused with
    /// `invalidPatch`. Nothing on ``CalendarEventPatch`` can produce one, which
    /// is the point of it being a type rather than a dictionary.
    @Test("no patch this type can build names a JSON-pointer path")
    func noPatchPaths() throws {
        var patch = CalendarEventPatch()
        patch.setTitle("Standup (moved)")
        patch.setStart(try localTime("2026-08-03T10:00:00"))
        patch.setDuration("PT30M")
        patch.setStatus(.tentative)
        patch.setCalendarID(CalendarID("10543"))
        patch.setLocation("Room 2")
        patch.setShowWithoutTime(false)
        patch.setDescription("Notes")

        #expect(patch.namedProperties.allSatisfy { $0.contains("/") == false })
        #expect(
            patch.namedProperties == [
                "calendarId", "description", "duration", "locations", "showWithoutTime",
                "start", "status", "title",
            ])
    }

    /// An absent property means "leave it alone", so clearing has to be said
    /// out loud — and an empty string would be stored as an empty description,
    /// which is a different event to one with none.
    @Test("clearing a description or a location sends an explicit null")
    func clearingIsExplicit() throws {
        var cleared = CalendarEventPatch()
        cleared.setDescription(nil)
        cleared.setLocation(nil)

        #expect(try string(cleared) == #"{"description":null,"locations":null}"#)

        var emptied = CalendarEventPatch()
        emptied.setDescription("")

        #expect(try string(emptied) == #"{"description":null}"#)
    }

    @Test("clearing a recurrence rule sends null rather than an empty array")
    func clearingRecurrence() throws {
        var patch = CalendarEventPatch()
        patch.setRecurrenceRule(nil)

        #expect(try string(patch) == #"{"recurrenceRules":null}"#)
    }

    /// `recurrenceOverrides` is **replaced whole**: send one override and every
    /// other exception on the series is dropped. Read them, change the one,
    /// send them all back.
    @Test("recurrenceOverrides replaces the entire map, keyed by the original start")
    func recurrenceOverridesReplaceWhole() throws {
        var moved = RecurrenceOverride()
        moved.setStart(try localTime("2026-08-07T11:00:00"))
        moved.setTitle("Standup (Retro-Woche)")

        var patch = CalendarEventPatch()
        patch.setRecurrenceOverrides([
            try localTime("2026-08-07T10:00:00"): moved,
            try localTime("2026-08-14T10:00:00"): .excluded,
        ])

        let json = try string(patch)

        // Keyed by where each occurrence *was*; the start inside says where it
        // went. Filing under the moved start records an exception for an
        // occurrence that was never there.
        #expect(
            json
                == #"{"recurrenceOverrides":{"2026-08-07T10:00:00":"#
                + #"{"start":"2026-08-07T11:00:00","title":"Standup (Retro-Woche)"},"#
                + #""2026-08-14T10:00:00":{"excluded":true}}}"#)
    }

    /// The only way to cancel a single occurrence: there is no writable id for
    /// one, so "cancel this Tuesday" is an override on the series rather than a
    /// destroy.
    @Test("an excluded occurrence is the only way to cancel one")
    func excludedOverride() throws {
        #expect(try string(RecurrenceOverride.excluded) == #"{"excluded":true}"#)

        // A cancelled status is a different thing: the occurrence keeps its
        // row, leaves the query and still resolves.
        var cancelled = RecurrenceOverride()
        cancelled.setStatus(.cancelled)

        #expect(try string(cancelled) == #"{"status":"cancelled"}"#)
    }

    // MARK: - CalendarEvent/set, the whole request

    /// There is no `ifInState` argument to send, and that is the design: the
    /// state is the constant `"fixed"`, so a guard built on it could only ever
    /// answer "nothing has changed". A guard that cannot fail is worse than
    /// none.
    @Test("a set carries no ifInState, because the server refuses one")
    func noIfInState() throws {
        var patch = CalendarEventPatch()
        patch.setTitle("Standup (moved)")

        let json = try encode(
            CalendarEventSet(
                accountID: account,
                update: [CalendarEventID("41"): patch],
                destroy: [CalendarEventID("44")]
            ))

        #expect(json.contains("ifInState") == false)
        #expect(
            json
                == #"{"accountId":"1","destroy":["44"],"update":{"41":{"title":"Standup (moved)"}}}"#
        )
        #expect(CalendarEventSet.fixedState.rawValue == "fixed")
    }

    @Test("empty create, update and destroy maps are omitted entirely")
    func emptyMapsOmitted() throws {
        #expect(
            try encode(CalendarEventSet(accountID: account, create: [:], destroy: []))
                == #"{"accountId":"1"}"#)
    }

    // MARK: - Helpers

    private func window(inCalendar: CalendarID? = nil) throws -> CalendarEventFilter {
        CalendarEventFilter(
            after: UTCDate(try #require(UTCDate.parse("2026-08-01T00:00:00Z"))),
            before: UTCDate(try #require(UTCDate.parse("2026-09-01T00:00:00Z"))),
            inCalendar: inCalendar
        )
    }

    private func localTime(_ text: String) throws -> LocalDateTime {
        try #require(LocalDateTime(rawValue: text))
    }

    private func encode<Method: JMAPMethod>(_ method: Method) throws -> String {
        try string(method.arguments)
    }

    private func string(_ value: some Encodable) throws -> String {
        String(decoding: try JMAPRequest.encoder.encode(value), as: UTF8.self)
    }
}
