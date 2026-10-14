import Foundation
import JMAPKit
import Testing

@testable import PLMailCore

/// The routes into the calendar from outside the app.
///
/// `App/` has no unit-test target and none of these paths can be reached
/// through a view from `swift test`, so the decisions live here as pure
/// functions and the shell binds a system callback to each — the same shape
/// `MailSpotlightIndex`'s planners take, and for the same reason.
@Suite("Calendar deep links")
struct CalendarDeepLinkTests {
    private func row(
        _ id: String, accountKey: String = "nas.local/7", start: String = "2026-08-03T10:00:00"
    ) -> CalendarOccurrenceSnapshot {
        CalendarOccurrenceSnapshot(
            accountKey: accountKey,
            occurrenceID: CalendarEventID(rawValue: id),
            seriesID: CalendarEventID(rawValue: "42"),
            recurrenceID: start,
            startLocal: start,
            startsAt: .distantPast,
            endsAt: .distantPast,
            title: "Standup")
    }

    @Test("a Spotlight identifier round-trips back into the two ids that wrote it")
    func roundTrip() throws {
        let written = row("42_20260803T080000Z")
        let uid = CalendarSpotlightIndex.uid(for: written)

        let ids = try #require(CalendarDeepLink.occurrence(forSpotlightUID: uid))

        #expect(ids.accountKey == "nas.local/7")
        #expect(ids.occurrenceID == CalendarEventID(rawValue: "42_20260803T080000Z"))
    }

    @Test("an account key with slashes in it survives, because the split is on the last hash")
    func awkwardAccountKey() throws {
        let uid = CalendarSpotlightIndex.uid(
            for: row("42_1", accountKey: "nas.local:8443/mail#2"))

        let ids = try #require(CalendarDeepLink.occurrence(forSpotlightUID: uid))

        #expect(ids.accountKey == "nas.local:8443/mail#2")
        #expect(ids.occurrenceID == CalendarEventID(rawValue: "42_1"))
    }

    @Test("an identifier that is not one of ours is refused rather than half-parsed")
    func refusesRubbish() {
        #expect(CalendarDeepLink.occurrence(forSpotlightUID: "") == nil)
        #expect(CalendarDeepLink.occurrence(forSpotlightUID: "no-separator") == nil)
        #expect(CalendarDeepLink.occurrence(forSpotlightUID: "#42_1") == nil)
        #expect(CalendarDeepLink.occurrence(forSpotlightUID: "nas.local/7#") == nil)
    }

    @Test("an occurrence lands on the day its wall clock names, not the day its instant does")
    func dayFromWallClock() throws {
        // `startsAt` here is `.distantPast`, which is the point: an anchor read
        // off the resolved instant would open the calendar in the year 1.
        let day = try #require(CalendarDeepLink.day(of: row("1", start: "2026-08-03T23:30:00")))

        #expect(day == CalendarDay(year: 2026, month: 8, day: 3))
    }

    @Test("a wall clock a different build wrote is refused rather than guessed at")
    func unparseableDay() {
        #expect(CalendarDeepLink.day(of: row("1", start: "2026-08-03")) == nil)
        #expect(CalendarDeepLink.day(of: row("1", start: "")) == nil)
    }

    @Test("a scene key reopens where the window was left, and a bad one falls back to today")
    func sceneKeys() {
        let today = CalendarDay(year: 2026, month: 8, day: 24)

        #expect(
            CalendarDeepLink.day(forSceneKey: "2027-03-01", today: today)
                == CalendarDay(year: 2027, month: 3, day: 1))
        #expect(CalendarDeepLink.day(forSceneKey: nil, today: today) == today)
        #expect(CalendarDeepLink.day(forSceneKey: "next tuesday", today: today) == today)
    }

    @Test("an intent with no date means today, in the device's zone and not in UTC")
    func intentDates() throws {
        let berlin = try #require(TimeZone(identifier: "Europe/Berlin"))
        // 23:30 UTC on the 3rd is already the 4th in Berlin.
        let lateEvening = Date(timeIntervalSince1970: 1_785_022_200)

        #expect(
            CalendarDeepLink.day(forIntentDate: lateEvening, in: berlin)
                != CalendarDeepLink.day(forIntentDate: lateEvening, in: .gmt))
        #expect(
            CalendarDeepLink.day(forIntentDate: nil, in: berlin)
                == CalendarDay(.now, in: berlin))
    }

    @Test("a dictated title that is only whitespace opens an honestly blank editor")
    func intentTitles() {
        #expect(CalendarDeepLink.title(forIntent: nil) == nil)
        #expect(CalendarDeepLink.title(forIntent: "") == nil)
        #expect(CalendarDeepLink.title(forIntent: "  \n ") == nil)
        #expect(CalendarDeepLink.title(forIntent: "  Retro  ") == "Retro")
    }
}

/// Resolving a route in from outside against the cache.
///
/// The read that decides whether a Spotlight result opens an event or says the
/// event is gone. An indexed event that lands nowhere is worse than one that
/// was never indexed, so the nil case is as much the point as the hit.
@Suite("Calendar deep link resolution")
struct CalendarDeepLinkResolutionTests {
    private let accountKey = "nas.local/7"

    private var window: CalendarWindow {
        // swift-format-ignore: NeverForceUnwrap
        CalendarWindow(
            from: CalendarDay(year: 2026, month: 8, day: 1),
            to: CalendarDay(year: 2026, month: 9, day: 1))!
    }

    private func makeStore() -> CalendarStore {
        CalendarStore(modelContainer: MailStack.makeContainer(inMemory: true))
    }

    private func store(_ store: CalendarStore) async throws {
        let events: [CalendarEvent] = try JSONDecoder().decode(
            [CalendarEvent].self,
            from: Data(
                """
                [{"id":"42_1","seriesId":"42","recurrenceId":"2026-08-03T09:00:00",
                  "title":"Standup","start":"2026-08-03T09:00:00","duration":"PT15M"}]
                """.utf8))

        _ = try await store.replaceOccurrences(
            events, in: window, accountKey: accountKey, zone: .gmt)
    }

    @Test("a cached occurrence is found by its synthetic id alone")
    func found() async throws {
        let cache = makeStore()
        try await store(cache)

        let row = try await cache.occurrence(
            CalendarEventID(rawValue: "42_1"), accountKey: accountKey)

        let found = try #require(row)

        #expect(found.title == "Standup")
        #expect(CalendarDeepLink.day(of: found) == CalendarDay(year: 2026, month: 8, day: 3))
    }

    @Test("an occurrence the cache no longer holds resolves to nil rather than to an empty screen")
    func vanished() async throws {
        let cache = makeStore()
        try await store(cache)

        // Exactly what a cancelled meeting looks like: the window is
        // re-queried and the row is simply absent from the answer.
        _ = try await cache.replaceOccurrences(
            [], in: window, accountKey: accountKey, zone: .gmt)

        #expect(
            try await cache.occurrence(
                CalendarEventID(rawValue: "42_1"), accountKey: accountKey) == nil)
    }

    @Test("another account's key does not resolve this account's occurrence")
    func scopedToTheAccount() async throws {
        let cache = makeStore()
        try await store(cache)

        #expect(
            try await cache.occurrence(
                CalendarEventID(rawValue: "42_1"), accountKey: "other.local/1") == nil)
    }
}

/// Who owns a tapped Spotlight result.
///
/// Both indexes write `accountKey#id` and the activity carries no domain, so
/// the shell has to ask. Getting this backwards opens a conversation that does
/// not exist for every event tap — the dead end that indexing events was
/// supposed to close.
@Suite("Spotlight ownership")
struct CalendarSpotlightOwnershipTests {
    @Test("an index with no record claims nothing, so a conversation is left to the mail branch")
    func emptyRecordClaimsNothing() {
        #expect(CalendarSpotlightIndex.isIndexed("nas.local/7#thread-9", in: [:]) == false)
    }

    @Test("an index claims exactly the identifiers it wrote and no neighbours")
    func claimsOnlyItsOwn() {
        let written = CalendarOccurrenceSnapshot(
            accountKey: "nas.local/7",
            occurrenceID: CalendarEventID(rawValue: "42_1"),
            seriesID: CalendarEventID(rawValue: "42"),
            recurrenceID: "2026-08-03T09:00:00",
            startLocal: "2026-08-03T09:00:00",
            startsAt: .distantPast,
            endsAt: .distantPast,
            title: "Standup")
        let record = [
            CalendarSpotlightIndex.uid(for: written): CalendarSpotlightIndex.signature(of: written)
        ]

        #expect(CalendarSpotlightIndex.isIndexed("nas.local/7#42_1", in: record))
        #expect(CalendarSpotlightIndex.isIndexed("nas.local/7#42_2", in: record) == false)
        // A conversation from the mail index, which shares the shape exactly.
        #expect(CalendarSpotlightIndex.isIndexed("nas.local/7#T9", in: record) == false)
    }
}
