import Foundation

/// `Calendar/get` — and it is the **entire** Calendar surface.
///
/// There is no `Calendar/query`, no `Calendar/changes` and no `Calendar/set`: a
/// user has a handful of calendars and there is nothing for a query to page,
/// they are provisioned server-side, and the state is the literal `"fixed"`.
/// Refreshing the list means fetching it again.
///
/// Another user's calendar comes back in `notFound` rather than as an error —
/// "there is no calendar 41 for you" and "calendar 41 is somebody else's" have
/// to be the same sentence.
public struct CalendarGet: JMAPMethod {
    public static let name = "Calendar/get"
    public static let capability = Capability.calendars

    public struct Arguments: Encodable, Sendable {
        public var accountID: AccountID

        /// **Explicit `null` rather than omitted** when asking for every
        /// calendar, as with `Mailbox/get`: JMAP distinguishes "all of them"
        /// from "none of them", and only the array form says the latter.
        public var ids: [CalendarID]?

        /// Narrows the published properties. `id` comes back regardless, which
        /// is why it is the one non-optional on ``JMAPCalendar``.
        public var properties: [String]?

        /// Written out by hand because `ids: null` must appear in the JSON.
        /// `encodeIfPresent` would omit the key and ask for something else.
        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: JMAPCodingKey.self)

            try container.encode(accountID, forKey: JMAPCodingKey("accountId"))

            if let ids {
                try container.encode(ids, forKey: JMAPCodingKey("ids"))
            } else {
                try container.encodeNil(forKey: JMAPCodingKey("ids"))
            }

            try container.encodeIfPresent(properties, forKey: JMAPCodingKey("properties"))
        }
    }

    public typealias Result = GetResult<JMAPCalendar>

    public var arguments: Arguments

    public init(accountID: AccountID, ids: [CalendarID]? = nil, properties: [String]? = nil) {
        arguments = Arguments(accountID: accountID, ids: ids, properties: properties)
    }
}

extension GetResult where Object == JMAPCalendar {
    /// Where a new event goes when the user has not chosen.
    ///
    /// By the flag rather than by `role == "default"`: the role vocabulary is
    /// open, and a second role meaning the same thing would silently take over.
    public var defaultCalendar: JMAPCalendar? {
        list.first { $0.isDefault == true }
    }

    /// What a calendar picker may offer. Writability is ``CalendarRights`` and
    /// nothing else — see ``JMAPCalendar/isWritable``.
    public var writableCalendars: [JMAPCalendar] {
        list.filter(\.isWritable)
    }
}

/// `CalendarEvent/query` — what falls in a window, ordered by start.
///
/// **``expandRecurrences`` switches the unit from the series to the
/// occurrence.** Omitted answers one id per *series* overlapping the window,
/// de-duplicated and ordered by each series' first occurrence inside it. True
/// answers one id per *occurrence*, in instance-start order — a moved override
/// sorting at its moved time, an excluded one absent — with `position`, `limit`
/// and `total` counting occurrences rather than series. A one-off keeps its
/// plain series id either way, so a window with nothing recurring in it answers
/// both identically.
///
/// That is what turns a month into **one round trip instead of thirty-one**.
/// Clients are forbidden from expanding rules themselves, because a phone and a
/// browser would disagree at DST boundaries and on overridden instances.
///
/// The refusals are the specification: no filter or `{}` is
/// `unsupportedFilter`; a `FilterOperator`, an unknown condition and `anchor`
/// likewise; any `sort` is `unsupportedSort`; a `timeZone` argument alongside
/// expansion is `invalidArguments`; and an expanded window reaching past the
/// account's `materialisedHorizon` is `cannotCalculateOccurrences`. None of
/// those arguments exist on this type, which is where they are cheapest to
/// refuse.
public struct CalendarEventQuery: JMAPMethod {
    public static let name = "CalendarEvent/query"
    public static let capability = Capability.calendars

    public struct Arguments: Encodable, Sendable {
        public var accountID: AccountID

        /// Mandatory. See ``CalendarEventFilter``.
        public var filter: CalendarEventFilter

        /// Must be a non-negative `Int` or the server answers
        /// `invalidArguments`. There is no `anchor`, so this and ``limit`` are
        /// the only paging there is.
        public var position: Int?

        /// Clamped to 500 server-side; null or larger becomes 500. Page in
        /// ``CalendarEventGet/maxEventsInGet`` chunks rather than 500, because
        /// what pairs with this is a get with a fifth of core's ceiling.
        public var limit: Int?

        /// **Nil rather than `false`** when collapsed — see ``init``.
        public var expandRecurrences: Bool?

        private enum CodingKeys: String, CodingKey {
            case accountID = "accountId"
            case filter, position, limit, expandRecurrences
        }
    }

    public struct Result: Decodable, Sendable {
        public var accountID: AccountID

        /// Always the literal `"fixed"`. **Not a sync cursor**: store it and
        /// hand it back if a `/changes` ever appears, but never compare two of
        /// them and conclude nothing has changed.
        public var queryState: StateToken

        /// Always false — there is no `CalendarEvent/queryChanges`.
        public var canCalculateChanges: Bool

        public var position: Int

        /// Ids in start order — not id order, and not the series' own start,
        /// which for a recurring event is often long before the window.
        ///
        /// What one names depends on the query: a **series** placed at its
        /// first occurrence inside the window, or with ``expandRecurrences``
        /// one **occurrence** placed at its own start. An occurrence id is
        /// opaque and belongs in a ``CalendarEventGet``, nowhere else.
        public var ids: [CalendarEventID]

        /// Always present, unlike `Mailbox/query`. Counts whatever ``ids``
        /// names, so it counts occurrences on an expanded query.
        public var total: Int?

        /// Echoes the requested limit, not the server's 500 cap.
        public var limit: Int?

        private enum CodingKeys: String, CodingKey {
            case accountID = "accountId"
            case queryState, canCalculateChanges, position, ids, total, limit
        }
    }

    public var arguments: Arguments

    /// `expandRecurrences` is **omitted from the JSON when false**, rather than
    /// sent as `false`. The two are documented to behave identically, so
    /// sending the argument only when it is wanted keeps a collapsed query
    /// byte-for-byte what an instance predating the feature has always been
    /// asked — which is what lets this client talk to a server that has never
    /// heard of it.
    public init(
        accountID: AccountID,
        filter: CalendarEventFilter,
        position: Int = 0,
        limit: Int? = nil,
        expandRecurrences: Bool = false
    ) {
        precondition(
            position >= 0,
            "CalendarEvent/query refuses a negative position with invalidArguments; page forward "
                + "with position + limit."
        )

        arguments = Arguments(
            accountID: accountID,
            filter: filter,
            position: position,
            limit: limit,
            expandRecurrences: expandRecurrences ? true : nil
        )
    }
}

/// `CalendarEvent/get`, which resolves a series id and an occurrence id alike.
///
/// That is what makes expansion usable at all: a client pairs ``CalendarEventQuery``
/// with this on `#ids` in one request, and ids the getter refused would leave
/// the feature a list of strings nothing accepts.
///
/// An occurrence id answers the series with its stored override merged in, plus
/// ``CalendarEvent/seriesID``, ``CalendarEvent/recurrenceID`` and the
/// occurrence's own `start`/`duration`; `recurrenceRules` and
/// `recurrenceOverrides` come back null.
public struct CalendarEventGet: JMAPMethod {
    public static let name = "CalendarEvent/get"
    public static let capability = Capability.calendars

    /// The account capability's value, and a floor to chunk by when no Session
    /// is to hand.
    ///
    /// **100, not core's `maxObjectsInGet` of 500.** `CalendarEventRepository`
    /// offers only an ownership-scoped single-id lookup, so a get is one query
    /// per id; over the ceiling is `requestTooLarge`. Expanded, the ceiling
    /// counts *occurrences*, which a busy month reaches long before it reaches
    /// 100 series. Read `maxEventsInGet` off the Session where one is
    /// available — an instance configured for more should not be second-guessed
    /// by its own client.
    public static let maxEventsInGet = 100

    public struct Arguments: Encodable, Sendable {
        public var accountID: AccountID

        /// **Required.** `null` is `requestTooLarge`, not "return everything" —
        /// which is why this is not an optional. Reach events through
        /// ``CalendarEventQuery``.
        public var ids: Argument<[CalendarEventID]>

        public var properties: [String]?

        /// Written out by hand because ``ids`` may encode as `ids` or as
        /// `#ids`, and the synthesised encoder cannot vary a key.
        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: JMAPCodingKey.self)

            try container.encode(accountID, forKey: JMAPCodingKey("accountId"))
            try ids.encode(into: &container, as: "ids")
            try container.encodeIfPresent(properties, forKey: JMAPCodingKey("properties"))
        }
    }

    public typealias Result = GetResult<CalendarEvent>

    public var arguments: Arguments

    public init(
        accountID: AccountID,
        ids: Argument<[CalendarEventID]>,
        properties: [String]? = nil
    ) {
        if case .value(let list) = ids {
            precondition(
                list.count <= Self.maxEventsInGet,
                """
                CalendarEvent/get takes at most \(Self.maxEventsInGet) ids — the account's \
                maxEventsInGet, a fifth of core's maxObjectsInGet. Over it is requestTooLarge; \
                chunk the ids.
                """
            )
        }

        arguments = Arguments(accountID: accountID, ids: ids, properties: properties)
    }
}

extension CalendarEventGet {
    /// Enough to **place** one occurrence, and nothing a series row already
    /// holds.
    ///
    /// The list an expanded query's back-referenced get asks for. A month of a
    /// busy calendar is a lot of occurrences and each one is the whole series
    /// repeated — description, location, participants — so asking for the
    /// fields a detail screen draws from the series would move that text once
    /// per occurrence over a domestic uplink.
    ///
    /// `seriesId` earns its place twice over: it is the row an occurrence hangs
    /// off, and the only id `CalendarEvent/set` will accept back.
    public static let occurrenceProperties = [
        "id", "seriesId", "recurrenceId", "title", "start", "duration", "timeZone",
        "showWithoutTime", "status",
    ]
}

extension GetResult where Object == CalendarEvent {
    /// The events in the order asked for.
    ///
    /// `CalendarEvent/get` happens to preserve the requested order today, which
    /// is the opposite of `Email/get`. That is not something to build on: the
    /// same repository pattern is underneath, and a query paired with a get
    /// renders in whatever `list` says. Going through here costs one map and
    /// removes the question.
    public func ordered(by ids: [CalendarEventID]) -> [CalendarEvent] {
        let byID = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        return ids.compactMap { byID[$0] }
    }
}
