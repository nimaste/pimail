import Foundation
import Testing

@testable import JMAPKit

/// `start` is a JSCalendar LocalDateTime and `created`/`updated` are Z-suffixed
/// UTC instants. They sit side by side on one object, and sharing a decoder
/// between them shifts every event by the reader's own offset — silently, and
/// only on the events whose zone differs from the device's. This suite is the
/// wall between them.
@Suite("LocalDateTime")
struct LocalDateTimeTests {

    @Test("the canonical spelling parses into its fields")
    func canonical() throws {
        let value = try #require(LocalDateTime(rawValue: "2026-08-03T10:00:00"))

        #expect(value.rawValue == "2026-08-03T10:00:00")
        #expect(value.components.year == 2026)
        #expect(value.components.month == 8)
        #expect(value.components.day == 3)
        #expect(value.components.hour == 10)
        #expect(value.components.minute == 0)
        #expect(value.components.second == 0)
    }

    /// `2026-06-02T09:00:00Z` is the single easiest mistake to make here, and
    /// the server refuses it for a reason worth repeating: it says UTC, the
    /// zone beside it says Europe/Berlin, and guessing which the client meant
    /// moves a meeting by hours in silence. Refusing at construction is the
    /// difference between a test failure and an `invalidProperties` arriving
    /// after the user has typed the whole event.
    @Test(
        "an instant, an offset, fractional seconds and a missing field are all refused",
        arguments: [
            "2026-08-03T10:00:00Z",
            "2026-08-03T10:00:00+02:00",
            "2026-08-03T10:00:00.500",
            "2026-08-03T10:00",
            "2026-08-03 10:00:00",
            "2026-8-3T10:00:00",
            "",
            "not a date at all",
        ])
    func refusedSpellings(text: String) {
        #expect(LocalDateTime(rawValue: text) == nil)
    }

    /// The server validates by reformatting and comparing back, so 30 February
    /// is refused rather than rolled forward into 2 March. A client that
    /// accepted it would send a date the server rejects, or worse, one that
    /// silently became a different day.
    @Test("a date that does not exist is refused rather than rolled over")
    func impossibleDates() {
        #expect(LocalDateTime(rawValue: "2026-02-30T09:00:00") == nil)
        #expect(LocalDateTime(rawValue: "2026-13-01T09:00:00") == nil)
        #expect(LocalDateTime(rawValue: "2026-04-31T09:00:00") == nil)
        #expect(LocalDateTime(rawValue: "2026-08-03T24:00:00") == nil)
        // 2026 is not a leap year; 2028 is.
        #expect(LocalDateTime(rawValue: "2026-02-29T09:00:00") == nil)
        #expect(LocalDateTime(rawValue: "2028-02-29T09:00:00") != nil)
    }

    /// A local time is not an instant, and turning one into an instant needs a
    /// zone the caller supplies. The two answers below differ by the offset —
    /// which is exactly the shift a shared decoder would apply invisibly.
    @Test("resolving a local time needs a zone, and different zones give different instants")
    func resolvingNeedsAZone() throws {
        let value = try #require(LocalDateTime(rawValue: "2026-08-03T10:00:00"))
        let zone = try #require(TimeZone(identifier: "Europe/Berlin"))
        let berlin = try #require(value.date(in: zone))
        let utc = try #require(value.date(in: .gmt))

        #expect(utc.timeIntervalSince(berlin) == 7200)
        #expect(utc == UTCDate.parse("2026-08-03T10:00:00Z"))
    }

    /// Formatting an instant in the wrong zone is the other half of the same
    /// bug, so the only constructor from a `Date` demands a zone.
    @Test("a local time built from an instant reads the wall clock of the zone given")
    func fromInstant() throws {
        let instant = try #require(UTCDate.parse("2026-08-03T08:00:00Z"))
        let berlin = try #require(TimeZone(identifier: "Europe/Berlin"))

        #expect(LocalDateTime(instant, in: berlin).rawValue == "2026-08-03T10:00:00")
        #expect(LocalDateTime(instant, in: .gmt).rawValue == "2026-08-03T08:00:00")
    }

    /// Chronological only because the format is fixed width and zero-padded —
    /// which is why the parser insists on both.
    @Test("ordering is chronological within one zone")
    func ordering() throws {
        let nine = try #require(LocalDateTime(rawValue: "2026-08-03T09:00:00"))
        let ten = try #require(LocalDateTime(rawValue: "2026-08-03T10:00:00"))
        let nextDay = try #require(LocalDateTime(rawValue: "2026-08-04T09:00:00"))

        #expect(nine < ten)
        #expect(ten < nextDay)
        #expect(nine == LocalDateTime(year: 2026, month: 8, day: 3, hour: 9, minute: 0, second: 0))
    }

    /// A `Z`-suffixed instant arriving where a local time belongs is either a
    /// contract change or this client decoding `created` into the wrong type,
    /// and both are worth a loud failure rather than an event drawn an offset
    /// away from where it belongs.
    @Test("decoding refuses an instant, and UTCDate refuses a local time")
    func decodersDoNotOverlap() throws {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                LocalDateTime.self, from: Data(#""2026-08-03T10:00:00Z""#.utf8))
        }

        #expect(
            try JSONDecoder().decode(
                LocalDateTime.self, from: Data(#""2026-08-03T10:00:00""#.utf8)
            ).rawValue == "2026-08-03T10:00:00")

        // The other direction: the instant decoder cannot read a local time.
        #expect(UTCDate.parse("2026-08-03T10:00:00") == nil)
    }

    @Test("encoding round-trips the canonical spelling and nothing else")
    func encoding() throws {
        let value = try #require(LocalDateTime(rawValue: "2026-08-03T10:00:00"))
        let json = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)

        #expect(json == #""2026-08-03T10:00:00""#)
    }

    /// Without `CodingKeyRepresentable` a `recurrenceOverrides` map keyed by a
    /// local time decodes as an array of alternating keys and values rather
    /// than as a JSON object — so the count would be wrong rather than the
    /// decode failing.
    @Test("a map keyed by a local time decodes as an object")
    func asDictionaryKey() throws {
        let body = Data(#"{"2026-08-07T10:00:00":{"excluded":true}}"#.utf8)
        let map = try JSONDecoder().decode([LocalDateTime: JSONValue].self, from: body)
        let key = try #require(LocalDateTime(rawValue: "2026-08-07T10:00:00"))

        #expect(map.count == 1)
        #expect(map[key] == .object(["excluded": .bool(true)]))
    }
}
