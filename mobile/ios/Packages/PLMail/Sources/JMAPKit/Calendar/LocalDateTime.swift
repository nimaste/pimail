import Foundation

/// A JSCalendar `LocalDateTime` (RFC 8984 §4.1.2): `2026-08-03T10:00:00`, with
/// **no offset and no trailing `Z`**.
///
/// A separate type from ``UTCDate`` because the two are different claims and
/// live side by side on the same object: `start`, `recurrenceId` and every
/// `recurrenceOverrides` key are local wall clocks, while `created` and
/// `updated` are `Z`-suffixed instants. Sharing one decoder between them is the
/// failure this type exists to prevent — a local time read as UTC shifts every
/// event by the reader's own offset, silently, and only on the events whose
/// zone differs from the device's.
///
/// It means "10:00 in the event's `timeZone`", or 10:00 wherever the reader
/// happens to be when no zone is published. It is therefore **not** an instant
/// and deliberately carries no ``Foundation/Date``: resolving one needs a zone
/// the caller has to supply, through ``date(in:)``.
///
/// Parsing is strict, matching `JmapEventWriter::LOCAL_DATE_TIME`. `Z`, an
/// offset, fractional seconds and a missing seconds field are all refused, and
/// so is a date that does not exist — `2026-02-30T09:00:00` round-trips to
/// 2 March and is rejected on the way back, exactly as the server rejects it.
/// Refusing here rather than on the wire is the difference between a compile-
/// or test-time failure and `invalidProperties` arriving after the user has
/// typed the whole event.
public struct LocalDateTime: Hashable, Sendable, RawRepresentable {
    /// The one spelling the server stores and emits, for error messages and
    /// documentation. Never fed to a `DateFormatter` — see ``parse(_:)``.
    public static let format = "yyyy-MM-dd'T'HH:mm:ss"

    /// Exactly `yyyy-MM-ddTHH:mm:ss`. Fixed width is what makes ``Comparable``
    /// lexicographic and correct.
    static let length = 19

    public let rawValue: String

    /// Year through second, in no zone at all.
    ///
    /// Kept because every use of a local time — placing it on a grid, turning
    /// it into an instant — needs the fields rather than the string, and
    /// re-parsing per read would be the hot path of drawing a month.
    public let components: DateComponents

    /// Fails rather than traps on anything that is not the canonical spelling.
    /// A caller building a start from user input wants to know before it sends.
    public init?(rawValue: String) {
        guard let components = Self.parse(rawValue) else { return nil }

        self.rawValue = rawValue
        self.components = components
    }

    /// The wall clock this instant shows in `timeZone`.
    ///
    /// The only correct way to build one from a ``Foundation/Date``. Formatting
    /// an instant with a UTC formatter and dropping the `Z` is the mistake the
    /// server's own error message names, and it produces a time that is wrong
    /// by the device's offset on every event.
    public init(_ date: Date, in timeZone: TimeZone) {
        var calendar = Foundation.Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let parts = calendar.dateComponents(Self.fields, from: date)

        self.init(
            year: parts.year ?? 0,
            month: parts.month ?? 1,
            day: parts.day ?? 1,
            hour: parts.hour ?? 0,
            minute: parts.minute ?? 0,
            second: parts.second ?? 0
        )
    }

    /// Non-failable because the fields are already numbers; out-of-range values
    /// are formatted as given rather than silently rolled over, so a bad one
    /// shows up as an obviously wrong string instead of a plausible wrong date.
    public init(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) {
        rawValue =
            Self.pad(year, 4) + "-" + Self.pad(month, 2) + "-" + Self.pad(day, 2)
            + "T" + Self.pad(hour, 2) + ":" + Self.pad(minute, 2) + ":" + Self.pad(second, 2)

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second

        self.components = components
    }

    /// The instant this wall clock names in `timeZone`.
    ///
    /// Optional because a local time can name an hour that does not exist —
    /// 02:30 on a spring-forward morning — and answering with the hour beside
    /// it would move an event without saying so.
    public func date(in timeZone: TimeZone) -> Date? {
        var calendar = Foundation.Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        return calendar.date(from: components)
    }

    /// The fields a `LocalDateTime` carries, and no others — a zone or a era
    /// read out of a calendar here would travel with a value that has neither.
    static let fields: Set<Foundation.Calendar.Component> = [
        .year, .month, .day, .hour, .minute, .second,
    ]

    /// Strict, hand-rolled, and deliberately not a `DateFormatter`.
    ///
    /// A formatter with this pattern accepts a trailing `Z`, accepts an offset,
    /// and resolves against a locale and a calendar it was not given — all
    /// three of which turn a refusal into a wrong answer. The digits are
    /// checked by position and the date is validated by reformatting and
    /// comparing back, which is what `JmapEventWriter` does in PHP.
    static func parse(_ text: String) -> DateComponents? {
        let bytes = Array(text.utf8)

        guard bytes.count == length else { return nil }
        guard
            bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-"),
            bytes[10] == UInt8(ascii: "T"),
            bytes[13] == UInt8(ascii: ":"), bytes[16] == UInt8(ascii: ":")
        else { return nil }

        guard
            let year = number(bytes, 0..<4),
            let month = number(bytes, 5..<7),
            let day = number(bytes, 8..<10),
            let hour = number(bytes, 11..<13),
            let minute = number(bytes, 14..<16),
            let second = number(bytes, 17..<19)
        else { return nil }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second

        // UTC only to give the round trip a fixed zone; nothing about the
        // value is UTC. A zone with a DST gap would reject a legal wall clock.
        var calendar = Foundation.Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt

        guard let date = calendar.date(from: components) else { return nil }

        let roundTrip = calendar.dateComponents(fields, from: date)

        guard
            roundTrip.year == year, roundTrip.month == month, roundTrip.day == day,
            roundTrip.hour == hour, roundTrip.minute == minute, roundTrip.second == second
        else { return nil }

        return components
    }

    private static func number(_ bytes: [UInt8], _ range: Range<Int>) -> Int? {
        var value = 0

        for index in range {
            let digit = Int(bytes[index]) - Int(UInt8(ascii: "0"))
            guard (0...9).contains(digit) else { return nil }
            value = value * 10 + digit
        }

        return value
    }

    private static func pad(_ value: Int, _ width: Int) -> String {
        let digits = String(abs(value))
        let padding = String(repeating: "0", count: max(0, width - digits.count))

        return (value < 0 ? "-" : "") + padding + digits
    }
}

extension LocalDateTime: Comparable {
    /// Lexicographic, which is chronological only because the format is fixed
    /// width and zero-padded. It orders two local times **in the same zone**;
    /// comparing across zones is comparing wall clocks, not instants, and is
    /// the caller's problem to resolve with ``date(in:)``.
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

extension LocalDateTime: CustomStringConvertible {
    public var description: String { rawValue }
}

extension LocalDateTime: Codable {
    /// Throws on a `Z`-suffixed instant rather than accepting it.
    ///
    /// The server never emits one here, so a value that arrives is either a
    /// contract change or this client decoding `created` into the wrong type —
    /// and both are worth a loud failure in a test rather than an event drawn
    /// an offset away from where it belongs.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)

        guard let value = Self(rawValue: text) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription:
                    "Not a JSCalendar LocalDateTime (\(Self.format), no offset, no trailing Z): "
                    + text
            )
        }

        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Without this a `recurrenceOverrides` map keyed by ``LocalDateTime`` decodes
/// as an array of alternating keys and values rather than as a JSON object.
extension LocalDateTime: CodingKeyRepresentable {
    public var codingKey: any CodingKey { JMAPCodingKey(rawValue) }

    public init?(codingKey: some CodingKey) {
        self.init(rawValue: codingKey.stringValue)
    }
}
