import Foundation

/// One event, as JSCalendar (RFC 8984) plus plMail's envelope — a **series**,
/// or **one occurrence of one**.
///
/// Which of the two it is, is ``seriesID``. Present means this object came back
/// for an occurrence id, and then ``start``, ``duration`` and ``status`` are
/// that occurrence's own with its override already merged in, while
/// ``recurrenceRules`` and ``recurrenceOverrides`` are nulled by the server
/// because the draft says they MUST be. Absent means the series — and a one-off
/// event is always the series, since its single occurrence *is* the event.
///
/// Every property but ``id`` is optional, for the same reason ``Email``'s are:
/// `CalendarEvent/get` returns **exactly** the properties asked for, so a
/// `properties` filter comes back without `uid` or even `@type`. A non-optional
/// property would turn a narrowed get into a decode failure.
///
/// **This is a subset of what the server stores.** Events carry arbitrary
/// JSCalendar — an import can bring participants, alerts, links, virtual
/// locations and anything else the format defines — so a round trip through
/// this type is lossy and **must never be written back wholesale**. Send only
/// the properties the user changed, through ``CalendarEventPatch``.
public struct CalendarEvent: Hashable, Sendable, Decodable {
    /// The series' `calendar_event` row id, or a synthetic occurrence id.
    /// Always returned, whatever `properties` asked for.
    public var id: CalendarEventID

    /// JSCalendar's discriminator, always `"Event"` when present.
    public var type: String?

    /// Stable across servers where ``id`` is not. `<hex>@plmail` for events
    /// this product created, and kept verbatim when a client supplies one on
    /// create.
    public var uid: String?

    public var calendarID: CalendarID?
    public var title: String?

    /// Emitted only when non-empty, so nil and "" are the same event.
    public var description: String?

    /// A **local wall clock**, never an instant — see ``LocalDateTime``.
    ///
    /// On an occurrence this is where the instance **actually** is, read off
    /// the materialised occurrence row, which after an override is not
    /// ``recurrenceID``.
    public var start: LocalDateTime?

    /// ISO 8601, e.g. `PT1H`, `PT15M`, `P1D`. Left as a string because
    /// `Foundation` has no ISO 8601 duration parser and inventing one here
    /// would be inventing a second answer to how long an event is.
    public var duration: String?

    /// An IANA zone name, or **absent entirely**.
    ///
    /// Absent is the ordinary case rather than an edge: an all-day event
    /// carries no zone at all. Substituting the device's zone for a floating
    /// event turns a birthday into something that moves when the user travels.
    public var timeZone: String?

    /// The all-day flag, emitted by the server **only when true**.
    ///
    /// Optional rather than defaulted to `false` because an absent property and
    /// a property the get was not asked for are different answers, and only one
    /// of them is "not all day".
    public var showWithoutTime: Bool?

    /// On an occurrence this is overwritten to ``EventStatus/cancelled`` when
    /// the occurrence row is cancelled, which is **not** the series' status.
    public var status: EventStatus?

    /// Always published and **never writable** (§1.7). A client offering a
    /// privacy control would have to hide it again at the moment of saving.
    public var privacy: EventPrivacy?

    /// At most one, under a key the server chose, and carrying only `@type` and
    /// `name` — plMail stores a place as a **label**, not as coordinates.
    public var locations: [String: EventLocation]?

    /// At most one rule; the server refuses a second with `invalidProperties`.
    /// Null on an occurrence.
    public var recurrenceRules: [RecurrenceRule]?

    /// Per-occurrence patches, keyed by the occurrence's **original** start.
    ///
    /// Raw JSON rather than a typed shape, deliberately: an override is a
    /// *patch* over the series and may name any writable property, including
    /// `{"excluded": true}`. Decoding it into a fixed struct would silently
    /// drop whatever this client's version has not heard of, and the loss would
    /// only show when the map was written back — which replaces it whole.
    ///
    /// Null on an occurrence.
    public var recurrenceOverrides: [LocalDateTime: JSONValue]?

    public var sequence: Int?

    /// A **UTC instant**, `Z`-suffixed — unlike ``start``. The two are
    /// different types on the wire and must not share a decoder.
    public var created: UTCDate?

    /// A UTC instant, as ``created``.
    public var updated: UTCDate?

    /// Derived server-side, and **not** the same claim as
    /// `recurrenceRules?.isEmpty == false`.
    ///
    /// A rule the server could not convert is stored verbatim and expands to a
    /// single occurrence, so an event can carry a rule and still not recur.
    /// Read this; do not infer it. The two disagree exactly on the imported
    /// events a user is most likely to notice.
    public var isRecurring: Bool?

    /// plMail's extension: what this was extracted *from*.
    ///
    /// **Null means a person made it** — that null-versus-set test is the
    /// server's own `isExtracted()`, which is why this is a double optional in
    /// spirit and why ``isExtracted`` reads it rather than each call site.
    public var kind: ExtractionKind?

    /// plMail's extension: where the event came from.
    public var source: EventSource?

    /// plMail's extension, present **exactly when** ``id`` names an occurrence.
    ///
    /// The only sanctioned route from an occurrence back to something writable,
    /// and the only sanctioned way to learn which series an occurrence belongs
    /// to. `CalendarEvent/set` refuses an occurrence id **by name**, pointing
    /// at this property, so every write goes to this id with a
    /// `recurrenceOverrides` patch keyed by ``recurrenceID``.
    public var seriesID: CalendarEventID?

    /// The occurrence's **original** start — never where an override moved it,
    /// which is ``start``.
    ///
    /// The key a `recurrenceOverrides` patch has to be filed under, which is
    /// what makes it worth keeping beside ``start``. Move an occurrence and the
    /// two differ; file the patch under ``start`` and the server records an
    /// exception for an occurrence that was never there.
    public var recurrenceID: LocalDateTime?

    /// The zone ``recurrenceID`` is read in — **UTC for a floating series**,
    /// which is not the event's own zone and not the device's.
    public var recurrenceIDTimeZone: String?

    private enum CodingKeys: String, CodingKey {
        case type = "@type"
        case calendarID = "calendarId"
        case seriesID = "seriesId"
        case recurrenceID = "recurrenceId"
        case recurrenceIDTimeZone = "recurrenceIdTimeZone"
        case id, uid, title, description, start, duration, timeZone, showWithoutTime
        case status, privacy, locations, recurrenceRules, recurrenceOverrides
        case sequence, created, updated, isRecurring, kind, source
    }
}

extension CalendarEvent {
    /// Whether this object is one occurrence of a series rather than the series.
    public var isOccurrence: Bool { seriesID != nil }

    /// The id an edit is addressed to: the series', which for a one-off is its
    /// own.
    ///
    /// **Never derived from ``id``.** Reading the series out of an occurrence
    /// id is client-side recurrence expansion through the back door, and the
    /// server mints ids this client is not entitled to understand.
    public var writableID: CalendarEventID { seriesID ?? id }

    /// Whether the server extracted this from a message rather than a person
    /// typing it.
    ///
    /// `kind == nil` is the server's own test, so an extracted event whose kind
    /// this client has not heard of still reads as extracted.
    public var isExtracted: Bool { kind != nil }

    /// The one place a location is stored, as a plain label.
    ///
    /// The map key is the server's own choice on the way back and nothing may
    /// read it — a client addressing a location by key would be addressing
    /// something it did not assign.
    public var locationName: String? {
        locations?.values.compactMap(\.name).first
    }
}

// MARK: - Body types

/// A place, as a label rather than as coordinates — which is all plMail stores,
/// and all `CalendarEvent/set` accepts. A key other than `@type` or `name` is
/// `invalidProperties`, because it "would not survive the next save".
public struct EventLocation: Hashable, Sendable, Codable {
    public var type: String?
    public var name: String?

    public init(name: String?) {
        self.type = "Location"
        self.name = name
    }

    private enum CodingKeys: String, CodingKey {
        case type = "@type"
        case name
    }
}

/// A JSCalendar recurrence rule. **At most one per event**; the server refuses
/// a second with `invalidProperties`.
///
/// Both read and written, so the encoder is hand-written: a decoded rule keeps
/// whatever the server sent, and an encoded one must carry `@type` and omit
/// what it does not set, because a null `interval` is not the same request as
/// an absent one.
public struct RecurrenceRule: Hashable, Sendable, Codable {
    public var type: String?

    /// `daily`, `weekly`, `monthly`, `yearly` — the five choices this product
    /// writes on either surface. Anything more elaborate arrives from an
    /// invitation, an import or a mirror and is carried faithfully, never
    /// composed here.
    public var frequency: String?

    public var interval: Int?
    public var count: Int?

    /// A ``LocalDateTime``, like ``CalendarEvent/start`` — not an instant.
    public var until: LocalDateTime?

    public var byDay: [NDay]?
    public var byMonthDay: [Int]?

    public init(
        frequency: String?,
        interval: Int? = nil,
        count: Int? = nil,
        until: LocalDateTime? = nil,
        byDay: [NDay]? = nil,
        byMonthDay: [Int]? = nil
    ) {
        self.type = "RecurrenceRule"
        self.frequency = frequency
        self.interval = interval
        self.count = count
        self.until = until
        self.byDay = byDay
        self.byMonthDay = byMonthDay
    }

    private enum CodingKeys: String, CodingKey {
        case type = "@type"
        case frequency, interval, count, until, byDay, byMonthDay
    }

    /// Written out by hand so `@type` is always present and empty lists are
    /// omitted rather than sent as `[]` — the server reads an empty `byDay` as
    /// a rule with no days, which is not a rule anybody meant.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(type ?? "RecurrenceRule", forKey: .type)
        try container.encodeIfPresent(frequency, forKey: .frequency)
        try container.encodeIfPresent(interval, forKey: .interval)
        try container.encodeIfPresent(count, forKey: .count)
        try container.encodeIfPresent(until, forKey: .until)

        if let byDay, byDay.isEmpty == false {
            try container.encode(byDay, forKey: .byDay)
        }

        if let byMonthDay, byMonthDay.isEmpty == false {
            try container.encode(byMonthDay, forKey: .byMonthDay)
        }
    }
}

/// One day inside a ``RecurrenceRule``'s `byDay`.
public struct NDay: Hashable, Sendable, Codable {
    public var type: String?

    /// **Lower-case two-letter codes** — `mo`, `tu`, `we` — not the upper-case
    /// iCalendar spelling. An importer written against RFC 5545 gets this
    /// wrong silently, and a rule with `MO` simply never fires on a Monday.
    public var day: String

    public var nthOfPeriod: Int?

    public init(day: String, nthOfPeriod: Int? = nil) {
        self.type = "NDay"
        self.day = day
        self.nthOfPeriod = nthOfPeriod
    }

    private enum CodingKeys: String, CodingKey {
        case type = "@type"
        case day, nthOfPeriod
    }
}

// MARK: - Open vocabularies

/// `EventStatus`. A value outside this set is `invalidProperties` on a write,
/// so the ``other(_:)`` case exists only to survive a server that adds one.
public enum EventStatus: Hashable, Sendable, RawRepresentable, Codable {
    case confirmed
    case tentative
    case cancelled
    case other(String)

    /// What the writer applies when a create names no status.
    public static let `default` = EventStatus.confirmed

    public init(rawValue: String) {
        switch rawValue {
        case "confirmed": self = .confirmed
        case "tentative": self = .tentative
        case "cancelled": self = .cancelled
        default: self = .other(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .confirmed: "confirmed"
        case .tentative: "tentative"
        case .cancelled: "cancelled"
        case .other(let value): value
        }
    }

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// `EventPrivacy`. Read-only: `CalendarEvent/set` has no writer parameter for
/// it and refuses it by name.
public enum EventPrivacy: Hashable, Sendable, RawRepresentable, Decodable {
    case `public`
    case `private`
    case secret
    case other(String)

    public init(rawValue: String) {
        switch rawValue {
        case "public": self = .public
        case "private": self = .private
        case "secret": self = .secret
        default: self = .other(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .public: "public"
        case .private: "private"
        case .secret: "secret"
        case .other(let value): value
        }
    }

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }
}

/// `ExtractionKind` — what an extracted event was extracted *from*.
///
/// Open because the server may add cases, and an unrecognised kind must still
/// draw. `order` and `call` are defined server-side but nothing currently emits
/// them, so a client that special-cased the list would be special-casing two
/// values it will never see and missing the one added next.
public enum ExtractionKind: Hashable, Sendable, RawRepresentable, Decodable {
    case meeting
    case delivery
    case flight
    case train
    case lodging
    case dining
    case rental
    case ticket
    case order
    case call
    case other(String)

    public init(rawValue: String) {
        switch rawValue {
        case "meeting": self = .meeting
        case "delivery": self = .delivery
        case "flight": self = .flight
        case "train": self = .train
        case "lodging": self = .lodging
        case "dining": self = .dining
        case "rental": self = .rental
        case "ticket": self = .ticket
        case "order": self = .order
        case "call": self = .call
        default: self = .other(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .meeting: "meeting"
        case .delivery: "delivery"
        case .flight: "flight"
        case .train: "train"
        case .lodging: "lodging"
        case .dining: "dining"
        case .rental: "rental"
        case .ticket: "ticket"
        case .order: "order"
        case .call: "call"
        case .other(let value): value
        }
    }

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }
}

/// `EventSource` — where the event came from.
///
/// Note the **camelCase** wire values: `acceptedProposal`, `structuredData`,
/// `senderParser`, `remoteSync`. Spelling one of them in snake case matches
/// nothing and degrades to ``other(_:)`` without a word of complaint.
public enum EventSource: Hashable, Sendable, RawRepresentable, Decodable {
    case manual
    case acceptedProposal
    case ics
    case structuredData
    case senderParser
    /// The one source the server marks **untrusted**.
    case llm
    case remoteSync
    case booking
    case other(String)

    public init(rawValue: String) {
        switch rawValue {
        case "manual": self = .manual
        case "acceptedProposal": self = .acceptedProposal
        case "ics": self = .ics
        case "structuredData": self = .structuredData
        case "senderParser": self = .senderParser
        case "llm": self = .llm
        case "remoteSync": self = .remoteSync
        case "booking": self = .booking
        default: self = .other(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .manual: "manual"
        case .acceptedProposal: "acceptedProposal"
        case .ics: "ics"
        case .structuredData: "structuredData"
        case .senderParser: "senderParser"
        case .llm: "llm"
        case .remoteSync: "remoteSync"
        case .booking: "booking"
        case .other(let value): value
        }
    }

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }
}
