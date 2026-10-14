import Foundation

/// Which zone an event's `start` is read in, on a write.
///
/// **Three states on the wire and only two of them are values**, which is why
/// this is a type rather than a `String?`:
///
/// | Wire | Meaning |
/// |---|---|
/// | property omitted | "you decide" — the calendar's own zone is used |
/// | JSON `null` | JSCalendar **floating** time (RFC 8984 §4.1.2) |
/// | an IANA name | that zone |
///
/// Omission is expressed by passing no zone at all, so this deliberately has no
/// third case: on a patch an absent property already means "leave it alone",
/// and there is no spelling for going back to inheriting.
///
/// Reading `?? null` collapses the first two and quietly zones every floating
/// event a client sends — which is how a birthday starts moving when the user
/// travels, on exactly the events (all-day, imported with an explicit null
/// zone) where nobody thinks to look.
public enum EventTimeZone: Hashable, Sendable, Encodable {
    /// The same wall clock in every zone. Sent as JSON `null`. This is what an
    /// all-day event is.
    case floating

    /// An IANA zone name. A name the server does not recognise is
    /// `invalidProperties`.
    case zone(String)

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .floating: try container.encodeNil()
        case .zone(let name): try container.encode(name)
        }
    }
}

extension EventTimeZone {
    /// The wire value, as a ``JSONValue`` — how a patch stores it before the
    /// whole patch is encoded as one object.
    var jsonValue: JSONValue {
        switch self {
        case .floating: .null
        case .zone(let name): .string(name)
        }
    }
}
