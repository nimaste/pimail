import Foundation
import JMAPKit
import Testing

@testable import PLMailCore

/// The wire objects are decode-only by design — nothing in the app may build a
/// `CalendarEvent` and pretend the server said it — so the fixtures here are
/// JSON, which also keeps the tests honest about the shapes actually sent.
private func decode<T: Decodable>(_ json: String, as type: T.Type = T.self) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

@Suite("Calendar store")
struct CalendarStoreTests {
    private func makeStore() -> CalendarStore {
        CalendarStore(modelContainer: MailStack.makeContainer(inMemory: true))
    }

    private let accountKey = "nas.local/7"

    private var window: CalendarWindow {
        // swift-format-ignore: NeverForceUnwrap
        CalendarWindow(
            from: CalendarDay(year: 2026, month: 8, day: 1),
            to: CalendarDay(year: 2026, month: 9, day: 1))!
    }

    @Test("calendars are replaced wholesale, because the answer is the whole list")
    func replacesCalendars() async throws {
        let store = makeStore()
        let first: [JMAPCalendar] = try decode(
            """
            [{"id":"3","name":"Work","color":"#336699","sortOrder":1,"isVisible":true,
              "isDefault":true,"timeZone":"Europe/Berlin","role":"default","isSynced":false,
              "myRights":{"mayReadItems":true,"mayAddItems":true,"mayUpdateAll":true,
                          "mayRemoveItems":true,"mayDelete":false}},
             {"id":"4","name":"Personal","color":null,"sortOrder":2,"isVisible":false,
              "isDefault":false,"myRights":{"mayAddItems":false}}]
            """)

        let stored = try await store.replaceCalendars(first, accountKey: accountKey)

        #expect(stored.count == 2)
        #expect(stored.first?.name == "Work")
        #expect(stored.first?.colorHex == "#336699")
        #expect(stored.first?.mayAddItems == true)
        #expect(stored.last?.isVisible == false)
        #expect(stored.last?.mayAddItems == false)

        let second: [JMAPCalendar] = try decode(#"[{"id":"3","name":"Work"}]"#)
        let after = try await store.replaceCalendars(second, accountKey: accountKey)

        #expect(after.count == 1)
    }

    @Test("a calendar with no myRights is treated as not writable")
    func rightsDefaultClosed() async throws {
        let store = makeStore()
        let list: [JMAPCalendar] = try decode(#"[{"id":"3","name":"Work"}]"#)
        let stored = try await store.replaceCalendars(list, accountKey: accountKey)

        #expect(stored.first?.mayAddItems == false)
    }

    @Test("an occurrence id is never stored as a series")
    func occurrencesAreNotSeries() async throws {
        let store = makeStore()
        let events: [CalendarEvent] = try decode(
            """
            [{"id":"42","uid":"a@plmail","calendarId":"3","title":"Standup",
              "start":"2026-08-03T09:00:00","duration":"PT15M","isRecurring":true},
             {"id":"42_20260803T070000Z","seriesId":"42","recurrenceId":"2026-08-03T09:00:00",
              "title":"Standup","start":"2026-08-03T09:00:00","duration":"PT15M"}]
            """)

        try await store.upsertSeries(events, accountKey: accountKey)

        #expect(
            try await store.series(id: CalendarEventID(rawValue: "42"), accountKey: accountKey)
                != nil)
        #expect(
            try await store.series(
                id: CalendarEventID(rawValue: "42_20260803T070000Z"), accountKey: accountKey)
                == nil)
    }

    @Test("the three-state zone survives the round trip through the store")
    func threeStateZone() async throws {
        let store = makeStore()
        let events: [CalendarEvent] = try decode(
            """
            [{"id":"1","title":"Inherits","start":"2026-08-03T09:00:00"},
             {"id":"2","title":"Named","start":"2026-08-03T09:00:00","timeZone":"Europe/Berlin"},
             {"id":"3","title":"AllDay","start":"2026-08-03T00:00:00","showWithoutTime":true}]
            """)

        try await store.upsertSeries(events, accountKey: accountKey)

        let inherits = try await store.series(
            id: CalendarEventID(rawValue: "1"), accountKey: accountKey)
        let named = try await store.series(
            id: CalendarEventID(rawValue: "2"), accountKey: accountKey)
        let allDay = try await store.series(
            id: CalendarEventID(rawValue: "3"), accountKey: accountKey)

        // Absent: use the calendar's zone.
        #expect(inherits?.hasExplicitTimeZone == false)
        #expect(inherits?.timeZoneName == nil)
        // Named.
        #expect(named?.hasExplicitTimeZone == true)
        #expect(named?.timeZoneName == "Europe/Berlin")
        // Floating, which is what an all-day event is.
        #expect(allDay?.hasExplicitTimeZone == true)
        #expect(allDay?.timeZoneName == nil)
    }

    @Test("replacing a window drops occurrences the server no longer returns")
    func replaceIsTheOnlyDeletion() async throws {
        let store = makeStore()
        let calendars: [JMAPCalendar] = try decode(
            #"[{"id":"3","name":"Work","timeZone":"Europe/Berlin"}]"#)
        _ = try await store.replaceCalendars(calendars, accountKey: accountKey)

        let series: [CalendarEvent] = try decode(
            #"[{"id":"42","uid":"a@plmail","calendarId":"3","title":"Standup","start":"2026-08-03T09:00:00","duration":"PT15M"}]"#
        )
        try await store.upsertSeries(series, accountKey: accountKey)

        let both: [CalendarEvent] = try decode(
            """
            [{"id":"42_1","seriesId":"42","calendarId":"3","recurrenceId":"2026-08-03T09:00:00",
              "title":"Standup","start":"2026-08-03T09:00:00","duration":"PT15M"},
             {"id":"42_2","seriesId":"42","calendarId":"3","recurrenceId":"2026-08-10T09:00:00",
              "title":"Standup","start":"2026-08-10T09:00:00","duration":"PT15M"}]
            """)

        let written = try await store.replaceOccurrences(
            both, in: window, accountKey: accountKey, zone: .gmt)

        #expect(written == 2)
        #expect(try await store.occurrences(in: window, accountKey: accountKey).count == 2)

        let one: [CalendarEvent] = try decode(
            """
            [{"id":"42_1","seriesId":"42","calendarId":"3","recurrenceId":"2026-08-03T09:00:00",
              "title":"Standup","start":"2026-08-03T09:00:00","duration":"PT15M"}]
            """)
        _ = try await store.replaceOccurrences(
            one, in: window, accountKey: accountKey, zone: .gmt)

        // The cancelled instance is gone. There is no `/changes` to learn that
        // from, so absence from the answer is the only signal there is.
        #expect(try await store.occurrences(in: window, accountKey: accountKey).count == 1)
    }

    @Test("an occurrence outside the window is dropped rather than stored")
    func overhangDropped() async throws {
        let store = makeStore()
        let outside: [CalendarEvent] = try decode(
            """
            [{"id":"9_1","seriesId":"9","recurrenceId":"2026-07-31T23:00:00","title":"Edge",
              "start":"2026-07-31T23:00:00","duration":"PT1H"}]
            """)

        let written = try await store.replaceOccurrences(
            outside, in: window, accountKey: accountKey, zone: .gmt)

        #expect(written == 0)
    }

    @Test("a series nothing places any more is swept, since it cannot be drawn")
    func sweepsUnplacedSeries() async throws {
        let store = makeStore()
        let series: [CalendarEvent] = try decode(
            #"[{"id":"42","title":"Gone","start":"2026-08-03T09:00:00"}]"#)
        try await store.upsertSeries(series, accountKey: accountKey)

        _ = try await store.replaceOccurrences([], in: window, accountKey: accountKey, zone: .gmt)

        #expect(
            try await store.series(id: CalendarEventID(rawValue: "42"), accountKey: accountKey)
                == nil)
    }

    @Test("two occurrences of one series on one day both survive")
    func twoOnOneDay() async throws {
        let store = makeStore()
        let events: [CalendarEvent] = try decode(
            """
            [{"id":"42_a","seriesId":"42","recurrenceId":"2026-08-03T09:00:00","title":"Standup",
              "start":"2026-08-03T09:00:00","duration":"PT15M"},
             {"id":"42_b","seriesId":"42","recurrenceId":"2026-08-03T16:00:00","title":"Standup",
              "start":"2026-08-03T16:00:00","duration":"PT15M"}]
            """)

        let written = try await store.replaceOccurrences(
            events, in: window, accountKey: accountKey, zone: .gmt)

        #expect(written == 2)
    }

    @Test("the cache answers availability before any session has been read")
    func availabilityFromCache() async throws {
        let store = makeStore()
        let availability = await CalendarAvailability(store: store)

        #expect(await availability.isAvailable == false)

        await availability.refresh(session: nil)
        #expect(await availability.isAvailable == false)

        let calendars: [JMAPCalendar] = try decode(#"[{"id":"3","name":"Work"}]"#)
        _ = try await store.replaceCalendars(calendars, accountKey: accountKey)

        // The regression the Android client dated 2026-08-06: the probe must
        // answer again once the world changed — a stored credential, an account
        // row — rather than once per process.
        await availability.refresh(session: nil)
        #expect(await availability.isAvailable)
    }
}

@Suite("Spoken event labels")
struct EventSpeechTests {
    private func cluster(_ rows: [EventRow]) -> EventCluster { EventCluster(members: rows) }

    @Test("a wall clock is spoken as itself and never converted")
    func doesNotConvert() {
        let time = EventSpeech.time(
            CalendarFixture.local("2026-08-03T09:00:00"), locale: Locale(identifier: "en_GB"))

        #expect(time.contains("09") || time.contains("9"))
    }

    @Test("a label carries title, time span and calendar")
    func label() {
        let text = EventSpeech.label(
            for: cluster([
                CalendarFixture.row(
                    id: "1", start: "2026-08-03T09:00:00", end: "2026-08-03T09:15:00")
            ]),
            locale: Locale(identifier: "en_GB"),
            allDayWord: "All day",
            floatingWord: "Floating time",
            cancelledWord: "Cancelled",
            mergedPhrase: { count, names in
                "in \(count) calendars, \(names.joined(separator: " and "))"
            }
        )

        #expect(text.hasPrefix("Standup, "))
        #expect(text.contains("Work"))
    }

    @Test("a merged cluster says so, because the dot is invisible to VoiceOver")
    func mergedSpoken() {
        let text = EventSpeech.label(
            for: cluster([
                CalendarFixture.row(
                    id: "1", start: "2026-08-03T09:00:00", end: "2026-08-03T09:15:00",
                    calendar: "1", calendarName: "Work"),
                CalendarFixture.row(
                    id: "2", start: "2026-08-03T09:00:00", end: "2026-08-03T09:15:00",
                    calendar: "2", calendarName: "Personal"),
            ]),
            locale: Locale(identifier: "en_GB"),
            allDayWord: "All day",
            floatingWord: nil,
            cancelledWord: nil,
            mergedPhrase: { count, names in
                "in \(count) calendars, \(names.joined(separator: " and "))"
            }
        )

        #expect(text.contains("in 2 calendars, Work and Personal"))
    }

    @Test("a floating event says it is floating")
    func floatingSpoken() {
        let text = EventSpeech.label(
            for: cluster([
                CalendarFixture.row(
                    id: "1", start: "2026-08-03T09:00:00", end: "2026-08-03T09:15:00", zone: nil)
            ]),
            locale: Locale(identifier: "en_GB"),
            allDayWord: "All day",
            floatingWord: "Floating time",
            cancelledWord: nil,
            mergedPhrase: { _, _ in "" }
        )

        #expect(text.contains("Floating time"))
    }

    @Test("an all-day event says all day rather than a pair of midnights")
    func allDaySpoken() {
        let text = EventSpeech.timeSpan(
            cluster([
                CalendarFixture.row(
                    id: "1", start: "2026-08-03T00:00:00", end: "2026-08-04T00:00:00",
                    zone: nil, isAllDay: true)
            ]),
            locale: Locale(identifier: "en_GB"),
            allDayWord: "All day"
        )

        #expect(text == "All day")
    }
}
