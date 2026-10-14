import Foundation

/// A JMAP `UTCDate` (RFC 8620 §1.4).
///
/// An explicit wrapper rather than a `JSONDecoder.dateDecodingStrategy`, for
/// two reasons: a global strategy silently applies to every `Date` in the
/// payload, and it makes the wire format invisible at the call site. Here the
/// type itself says "this field is a JMAP date".
///
/// Decoding is liberal — the server emits `2026-07-15T10:00:00Z` from
/// `EmailMapper::utcOrNull`, but nothing stops a future version emitting
/// fractional seconds, and a client that falls over on that is a client that
/// falls over on an upgrade. Encoding is strict and always emits the server's
/// own spelling.
public struct UTCDate: Hashable, Sendable, Comparable {
    public let date: Date

    public init(_ date: Date) {
        self.date = date
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.date < rhs.date }
}

extension UTCDate: Codable {
    /// `Date.ISO8601FormatStyle` rather than `ISO8601DateFormatter`: the
    /// formatter class is a reference type and not `Sendable`, so a shared
    /// instance cannot be a global under strict concurrency, and creating one
    /// per call is expensive enough to matter when decoding 500 emails.
    private static let encoding = Date.ISO8601FormatStyle(timeZone: .gmt)
    private static let decodingWithFractionalSeconds = Date.ISO8601FormatStyle(timeZone: .gmt)
        .time(includingFractionalSeconds: true)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)

        guard let date = Self.parse(text) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Not an RFC 3339 UTC date: \(text)"
            )
        }

        self.date = date
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(date.formatted(Self.encoding))
    }

    static func parse(_ text: String) -> Date? {
        (try? Date(text, strategy: encoding))
            ?? (try? Date(text, strategy: decodingWithFractionalSeconds))
    }
}
