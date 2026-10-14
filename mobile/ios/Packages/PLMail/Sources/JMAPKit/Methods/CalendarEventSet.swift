import Foundation

/// `CalendarEvent/set` — create, change and destroy event **series**.
///
/// **There is no `ifInState`, deliberately, and it is not an omission to fix.**
/// The server refuses one with `invalidArguments`: the state is the constant
/// `"fixed"`, so a guard built on it could only ever answer "nothing has
/// changed". A guard that cannot fail is worse than no guard — it reads as
/// conflict detection while providing none. Two clients editing one event take
/// turns, and reconciliation is re-fetching the window.
///
/// The writable vocabulary is **thirteen properties** and everything else is
/// refused by name, per object, in `notCreated`/`notUpdated`. Making the
/// refused set unrepresentable — ``NewCalendarEvent`` and
/// ``CalendarEventPatch`` have no way to name `participants`, `alerts`,
/// `links` or `privacy` — moves that from a round trip after the user has typed
/// the whole event to a compile error.
///
/// Destroying is a **real delete**, unlike `Email/set` where destroy means
/// Trash. There is no calendar bin to recover from, so a destructive control
/// here needs its own confirmation rather than borrowing mail's undo.
public struct CalendarEventSet: JMAPMethod {
    public static let name = "CalendarEvent/set"
    public static let capability = Capability.calendars

    /// The literal every calendar method returns, before and after a change
    /// that did happen.
    ///
    /// Stored and handed back if a `/changes` ever appears, rather than
    /// special-cased: should calendars later join the change log, tokens become
    /// sequences and a client still holding this fails the server's own digit
    /// check and is told to resync. That is free, correct degradation.
    public static let fixedState = StateToken(rawValue: "fixed")

    public struct Arguments: Encodable, Sendable {
        public var accountID: AccountID

        /// Keyed by a creation id the client chose, echoed back in `created`.
        public var create: [String: NewCalendarEvent]?

        /// Patches keyed by **series** id. An occurrence id here is refused by
        /// name — see ``CalendarSetError``.
        public var update: [CalendarEventID: CalendarEventPatch]?

        public var destroy: [CalendarEventID]?

        private enum CodingKeys: String, CodingKey {
            case accountID = "accountId"
            case create, update, destroy
        }
    }

    public struct Result: Decodable, Sendable {
        public var accountID: AccountID

        /// Both states are ``fixedState``.
        public var oldState: StateToken?
        public var newState: StateToken

        /// `{}` when empty, **never `[]`** — which is why this decodes as a
        /// dictionary and an empty-array fixture would fail loudly rather than
        /// quietly producing nothing.
        public var created: [String: CreatedCalendarEvent]?
        public var notCreated: [String: CalendarSetError]?

        /// Values are always `null`, meaning "no properties changed beyond what
        /// you asked for". The **key** is the whole answer.
        public var updated: [CalendarEventID: JSONValue]?
        public var notUpdated: [CalendarEventID: CalendarSetError]?

        public var destroyed: [CalendarEventID]?
        public var notDestroyed: [CalendarEventID: CalendarSetError]?

        private enum CodingKeys: String, CodingKey {
            case accountID = "accountId"
            case oldState, newState, created, notCreated, updated, notUpdated
            case destroyed, notDestroyed
        }
    }

    public var arguments: Arguments

    public init(
        accountID: AccountID,
        create: [String: NewCalendarEvent]? = nil,
        update: [CalendarEventID: CalendarEventPatch]? = nil,
        destroy: [CalendarEventID]? = nil
    ) {
        arguments = Arguments(
            accountID: accountID,
            create: create?.isEmpty == true ? nil : create,
            update: update?.isEmpty == true ? nil : update,
            destroy: destroy?.isEmpty == true ? nil : destroy
        )
    }
}

extension CalendarEventSet.Result {
    /// Whether any object in the batch was refused.
    ///
    /// A `CalendarEvent/set` succeeds at the method level and refuses per
    /// object, so a caller that only checked for a ``JMAPError`` would report a
    /// save that never happened as done.
    public var hasFailures: Bool {
        notCreated?.isEmpty == false || notUpdated?.isEmpty == false
            || notDestroyed?.isEmpty == false
    }

    /// The first refusal, for a caller with one place to show one.
    public var firstFailure: CalendarSetError? {
        notCreated?.sorted { $0.key < $1.key }.first?.value
            ?? notUpdated?.sorted { $0.key < $1.key }.first?.value
            ?? notDestroyed?.sorted { $0.key < $1.key }.first?.value
    }
}

// MARK: - What the server decided

/// What the server decided about a created event.
///
/// ``isRecurring`` is reported rather than inferred because it is derived
/// server-side: a rule plMail cannot convert is stored verbatim and expands to
/// one occurrence, so a create carrying a recurrence rule can come back
/// `false`. That is the answer, not a bug to work around.
public struct CreatedCalendarEvent: Hashable, Sendable, Decodable {
    public var id: CalendarEventID

    /// The uid the server minted, or the one the client supplied kept verbatim.
    ///
    /// Optional rather than defaulted to `""`, because a cache reconciles a
    /// created row against later refreshes on this value and `""` is not an
    /// identity — it is the absence of one, and one that compares equal to
    /// every other absence.
    public var uid: String?

    public var calendarID: CalendarID?
    public var isRecurring: Bool?
    public var sequence: Int?

    private enum CodingKeys: String, CodingKey {
        case calendarID = "calendarId"
        case id, uid, isRecurring, sequence
    }
}

/// One object's refusal, inside an otherwise-successful `CalendarEvent/set`.
///
/// Typed rather than raw JSON because §1.7's refusals are the ones a caller
/// acts on differently: ``MethodErrorType/forbidden`` means the calendar
/// mirrors somewhere read-only and the control should be greyed out;
/// `invalidProperties` names the offenders in ``properties`` and can point at a
/// field; `notFound` means the event or its calendar is gone; `invalidPatch`
/// means a JSON-pointer path was sent where a whole property belongs; and an
/// occurrence id in `update`/`destroy` is ``MethodErrorType/invalidArguments``
/// pointing at `seriesId` — **not** `notFound`, because this server minted the
/// id and a client told "no such event" would go looking for a bug in its own
/// id handling.
public struct CalendarSetError: Hashable, Sendable, Decodable {
    public var type: MethodErrorType

    /// The server's own sentence. Diagnostic only — **never shown to a user**,
    /// since it is untranslated English written for a developer.
    public var description: String?

    /// The offending property names, present on `invalidProperties`.
    ///
    /// This is what makes the refusal actionable: `["participants", "alerts"]`
    /// tells a caller exactly which fields it tried to write and must not, and
    /// a caller that only read ``type`` would know a save failed without
    /// knowing what to correct.
    public var properties: [String]?
}

extension CalendarSetError {
    /// The properties this refusal names, empty unless it is
    /// `invalidProperties`.
    public var invalidProperties: [String] {
        type == .invalidProperties ? (properties ?? []) : []
    }

    /// Whether the target calendar refuses writes because it mirrors somewhere
    /// that does not accept them. The one refusal a UI can prevent next time,
    /// by consulting ``JMAPCalendar/isWritable`` first.
    public var isReadOnlyCalendar: Bool { type == .forbidden }
}

// MARK: - Creating

/// An event being created.
///
/// The properties here are **exactly** what the server accepts, and that is the
/// whole design. `participants`, `alerts`, `links` and `privacy` are published
/// and carried across writes — an event that arrived by invitation keeps them
/// when you correct its title — but they are not yours to set, and naming one
/// comes back as `invalidProperties` after the user has typed the whole event.
/// There is no attachment support of any kind.
public struct NewCalendarEvent: Hashable, Sendable, Encodable {
    /// Required, and numeric server-side. Missing or non-numeric is
    /// `invalidProperties`; somebody else's calendar is `notFound`, never
    /// `forbidden`, which would confirm the id exists.
    public var calendarID: CalendarID

    /// Required and **non-empty** — the server's `string()` refuses `""` with
    /// `invalidProperties`, so an untitled event is not a thing that can exist.
    public var title: String

    /// A ``LocalDateTime``, never an instant. The type refuses any other
    /// spelling before the request is built.
    public var start: LocalDateTime

    /// ISO 8601. Absent means `PT1H`, or `P1D` when ``showWithoutTime`` — so
    /// leaving it nil is a decision, not a gap.
    public var duration: String?

    public var eventDescription: String?

    /// Nil omits the property, which means the calendar's own zone. See
    /// ``EventTimeZone`` for why nil and ``EventTimeZone/floating`` are
    /// different events.
    public var timeZone: EventTimeZone?

    /// The all-day flag. Sent only when true, because on a create `false` and
    /// absent are the same request and an omitted key cannot be mistaken for a
    /// client trying to clear something.
    public var showWithoutTime: Bool

    /// A place, as a plain label — one, not a list, and a name rather than a
    /// structure. More than one entry is `invalidProperties`, and so is any key
    /// but `@type` and `name`: offering coordinates would be offering something
    /// that silently does not survive the next save.
    public var location: String?

    /// Absent means ``EventStatus/confirmed``. A value outside the vocabulary
    /// is `invalidProperties` listing the legal ones.
    public var status: EventStatus

    /// At most one; a second is `invalidProperties`.
    public var recurrenceRule: RecurrenceRule?

    /// Keyed by each occurrence's **original** start.
    public var recurrenceOverrides: [LocalDateTime: RecurrenceOverride]?

    /// Settable **on create only** and immutable afterwards — `uid` in an
    /// update is `invalidProperties`, because the uid is the event's identity
    /// and a server that reissued it would break every reply and update sent
    /// about the meeting.
    ///
    /// Left nil for anything this app originates; the server mints a stable
    /// `<hex>@plmail`. Supply one only when re-creating an event that came from
    /// elsewhere and has to keep its identity across servers.
    public var uid: String?

    public init(
        calendarID: CalendarID,
        title: String,
        start: LocalDateTime,
        duration: String? = nil,
        eventDescription: String? = nil,
        timeZone: EventTimeZone? = nil,
        showWithoutTime: Bool = false,
        location: String? = nil,
        status: EventStatus = .confirmed,
        recurrenceRule: RecurrenceRule? = nil,
        recurrenceOverrides: [LocalDateTime: RecurrenceOverride]? = nil,
        uid: String? = nil
    ) {
        self.calendarID = calendarID
        self.title = title
        self.start = start
        self.duration = duration
        self.eventDescription = eventDescription
        self.timeZone = timeZone
        self.showWithoutTime = showWithoutTime
        self.location = location
        self.status = status
        self.recurrenceRule = recurrenceRule
        self.recurrenceOverrides = recurrenceOverrides
        self.uid = uid
    }

    /// Written out by hand: an omitted key and a null one are different
    /// requests here, and the synthesised encoder cannot express both.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: JMAPCodingKey.self)

        try container.encode("Event", forKey: JMAPCodingKey("@type"))
        try container.encode(calendarID, forKey: JMAPCodingKey("calendarId"))
        try container.encodeIfPresent(uid, forKey: JMAPCodingKey("uid"))
        try container.encode(title, forKey: JMAPCodingKey("title"))
        try container.encodeIfPresent(eventDescription, forKey: JMAPCodingKey("description"))
        try container.encode(start, forKey: JMAPCodingKey("start"))
        try container.encodeIfPresent(duration, forKey: JMAPCodingKey("duration"))

        // Present only when the caller chose a zone — omitted is "the
        // calendar's own", and there is no other way to spell that.
        if let timeZone {
            try container.encode(timeZone, forKey: JMAPCodingKey("timeZone"))
        }

        if showWithoutTime {
            try container.encode(true, forKey: JMAPCodingKey("showWithoutTime"))
        }

        if let location {
            try container.encode(
                CalendarLocations.map(name: location), forKey: JMAPCodingKey("locations"))
        }

        try container.encode(status, forKey: JMAPCodingKey("status"))

        if let recurrenceRule {
            try container.encode([recurrenceRule], forKey: JMAPCodingKey("recurrenceRules"))
        }

        if let recurrenceOverrides, recurrenceOverrides.isEmpty == false {
            try container.encode(
                recurrenceOverrides, forKey: JMAPCodingKey("recurrenceOverrides"))
        }
    }
}

// MARK: - Patching

/// A change to an existing event.
///
/// **Whole properties only.** A key containing a `/` is a JSON-pointer path,
/// which `Email/set` accepts and this method refuses with `invalidPatch` — the
/// writer takes whole values, so a partial one would be merged here against a
/// stored object the writer is about to rebuild, and the two merges would
/// disagree the first time a projection changed. Nothing on this type can
/// produce such a key, which is the point of it being a type rather than a
/// dictionary.
///
/// An update is a **patch layered over the stored event**: properties you do
/// not name are re-supplied from storage, so an unmentioned `description` is
/// "leave it alone" rather than "delete it". The exception is
/// ``recurrenceOverrides``, which when named is **replaced whole** — send one
/// override and every other exception on the series is dropped. Read them,
/// change the one, send them all back.
public struct CalendarEventPatch: Hashable, Sendable, Encodable {
    /// The named properties, in wire form. Private so no caller can insert a
    /// key with a `/` in it.
    private var fields: [String: JSONValue] = [:]

    public init() {}

    public var isEmpty: Bool { fields.isEmpty }

    /// The property names this patch will send, for tests and for logging.
    public var namedProperties: [String] { fields.keys.sorted() }

    public func encode(to encoder: any Encoder) throws {
        try fields.encode(to: encoder)
    }

    // MARK: Properties

    public mutating func setTitle(_ value: String) {
        fields["title"] = .string(value)
    }

    /// Nil clears the description. An empty string would be stored as an empty
    /// description instead, which is a different event to one with none.
    public mutating func setDescription(_ value: String?) {
        fields["description"] = value.flatMap { $0.isEmpty ? nil : JSONValue.string($0) } ?? .null
    }

    /// A ``LocalDateTime``, never an instant — the type will not hold one.
    public mutating func setStart(_ value: LocalDateTime) {
        fields["start"] = .string(value.rawValue)
    }

    public mutating func setDuration(_ value: String) {
        fields["duration"] = .string(value)
    }

    /// All three states are reachable on a patch except "go back to
    /// inheriting": an absent property already means "leave it alone", and the
    /// server has no spelling for un-setting a zone.
    public mutating func setTimeZone(_ value: EventTimeZone) {
        fields["timeZone"] = value.jsonValue
    }

    public mutating func setShowWithoutTime(_ value: Bool) {
        fields["showWithoutTime"] = .bool(value)
    }

    /// Nil takes the place off.
    public mutating func setLocation(_ name: String?) {
        fields["locations"] = CalendarLocations.value(name: name)
    }

    public mutating func setStatus(_ value: EventStatus) {
        fields["status"] = .string(value.rawValue)
    }

    /// Moving an event between calendars is a plain property change.
    public mutating func setCalendarID(_ value: CalendarID) {
        fields["calendarId"] = .string(value.rawValue)
    }

    /// Nil stops the event recurring.
    public mutating func setRecurrenceRule(_ value: RecurrenceRule?) {
        guard let value else {
            fields["recurrenceRules"] = .null
            return
        }

        fields["recurrenceRules"] = .array([value.jsonValue])
    }

    /// **Replaces the whole map.** Send every override the series should keep;
    /// an excluded occurrence is the only way to cancel a single one.
    public mutating func setRecurrenceOverrides(_ value: [LocalDateTime: RecurrenceOverride]) {
        fields["recurrenceOverrides"] = .object(
            Dictionary(uniqueKeysWithValues: value.map { ($0.key.rawValue, $0.value.jsonValue) }))
    }
}

/// One occurrence of a recurring series, changed or removed.
///
/// Keyed in ``CalendarEventPatch/setRecurrenceOverrides(_:)`` by the
/// occurrence's **original** start, so moving an occurrence keeps the key it had
/// before the move: the key says *which* occurrence, the `start` inside says
/// where it went. Filing it under the moved start records an exception for an
/// occurrence that was never there, and leaves the real one still drawn.
public struct RecurrenceOverride: Hashable, Sendable, Encodable {
    private var fields: [String: JSONValue] = [:]

    public init() {}

    /// Removes a single occurrence.
    ///
    /// **The only way to do it**: there is no writable id for one occurrence,
    /// so "cancel this Tuesday" is an override on the series rather than a
    /// destroy. It round-trips as `{"excluded": true}` — the occurrence is gone
    /// from `CalendarEvent/query` and `notFound` from the getter, but the
    /// exclusion is still in the object.
    public static let excluded: RecurrenceOverride = {
        var override = RecurrenceOverride()
        override.fields["excluded"] = .bool(true)
        return override
    }()

    public var isEmpty: Bool { fields.isEmpty }

    public func encode(to encoder: any Encoder) throws {
        try fields.encode(to: encoder)
    }

    var jsonValue: JSONValue { .object(fields) }

    public mutating func setTitle(_ value: String) {
        fields["title"] = .string(value)
    }

    public mutating func setDescription(_ value: String) {
        fields["description"] = .string(value)
    }

    /// Where this occurrence moved to. A ``LocalDateTime``, as everywhere else.
    public mutating func setStart(_ value: LocalDateTime) {
        fields["start"] = .string(value.rawValue)
    }

    public mutating func setDuration(_ value: String) {
        fields["duration"] = .string(value)
    }

    /// Note this leaves the occurrence **drawn** — a cancelled instance keeps
    /// its row and still resolves, because the answer to "wasn't there
    /// something today?" is more useful than a gap. Use ``excluded`` to remove
    /// it outright.
    public mutating func setStatus(_ value: EventStatus) {
        fields["status"] = .string(value.rawValue)
    }

    /// Nil takes the place off.
    public mutating func setLocation(_ name: String?) {
        fields["locations"] = CalendarLocations.value(name: name)
    }
}

// MARK: - Locations

/// The map form a single place takes on the wire.
///
/// The key is the server's own choice on the way back (`"1"`) and nothing may
/// read it — a client addressing a location by key would be addressing
/// something it did not assign.
enum CalendarLocations {
    static func map(name: String) -> [String: EventLocation] {
        ["1": EventLocation(name: name)]
    }

    /// A name of nil is JSON null, which is how a place is removed.
    static func value(name: String?) -> JSONValue {
        guard let name else { return .null }

        return .object(["1": .object(["@type": .string("Location"), "name": .string(name)])])
    }
}

extension RecurrenceRule {
    /// The write shape, as a ``JSONValue`` — how a patch stores a rule before
    /// the whole patch is encoded as one object. Mirrors ``encode(to:)``.
    var jsonValue: JSONValue {
        var object: [String: JSONValue] = ["@type": .string(type ?? "RecurrenceRule")]

        if let frequency { object["frequency"] = .string(frequency) }
        if let interval { object["interval"] = .int(interval) }
        if let count { object["count"] = .int(count) }
        if let until { object["until"] = .string(until.rawValue) }

        if let byDay, byDay.isEmpty == false {
            object["byDay"] = .array(byDay.map(\.jsonValue))
        }

        if let byMonthDay, byMonthDay.isEmpty == false {
            object["byMonthDay"] = .array(byMonthDay.map(JSONValue.int))
        }

        return .object(object)
    }
}

extension NDay {
    var jsonValue: JSONValue {
        var object: [String: JSONValue] = [
            "@type": .string(type ?? "NDay"),
            "day": .string(day),
        ]

        if let nthOfPeriod { object["nthOfPeriod"] = .int(nthOfPeriod) }

        return .object(object)
    }
}
