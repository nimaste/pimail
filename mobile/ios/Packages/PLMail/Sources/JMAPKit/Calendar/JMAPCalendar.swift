import Foundation

// MARK: - Id spaces

/// The id space of a `calendar` row. What `inCalendar`, `CalendarEvent.calendarId`
/// and `CalendarEvent/set`'s `calendarId` all consume — one space, no translation.
public enum CalendarNamespace: IdentifierNamespace {}

/// The id space of a `calendar_event` row **and** of the synthetic occurrence
/// ids an expanded query mints.
///
/// Deliberately one space rather than two. The server publishes both under
/// `CalendarEvent.id` and `CalendarEvent/get` resolves either, so splitting
/// them here would force a cast at the one place the distinction is invisible.
/// The distinction that *is* real — which of the two you are holding — is
/// ``CalendarEvent/seriesID`` being present, never anything read out of the id.
public enum CalendarEventNamespace: IdentifierNamespace {}

public typealias CalendarID = Identifier<CalendarNamespace>

/// A series id, or an opaque occurrence id. **Never parsed.**
///
/// An occurrence id looks like `42_20260803T080000Z` and a client that split it
/// on the underscore would be expanding recurrence rules by hand through the
/// back door: the separator is plMail's own choice, the timestamp is the
/// occurrence's *original* start rather than where an override moved it, and
/// the draft calls the id opaque. Read ``CalendarEvent/seriesID`` instead.
public typealias CalendarEventID = Identifier<CalendarEventNamespace>

// MARK: - Calendar

/// One calendar, from plMail's vendor `urn:plmail:params:jmap:calendars`
/// surface.
///
/// Named with the `JMAP` prefix because `Calendar` is `Foundation.Calendar`
/// everywhere else in this package, and a public type of that name in JMAPKit
/// would make `Calendar.current` ambiguous in every file of PLMailCore and
/// PLMailUI that imports this module.
///
/// There is no `Calendar/query`, no `Calendar/changes` and no `Calendar/set`:
/// the whole list arrives from one ``CalendarGet`` and the state is the literal
/// `"fixed"`. A client waiting for a changes call to tell it a calendar
/// appeared would wait forever.
public struct JMAPCalendar: Hashable, Sendable, Decodable {
    /// The only property `Calendar/get` returns regardless of a `properties`
    /// filter, which is why it is the only one that is not optional.
    public var id: CalendarID

    public var name: String?

    /// **`#rrggbb` hex**, and deliberately *not* the Tailwind token
    /// ``Mailbox/color`` carries.
    ///
    /// The two are different vocabularies in the database: a label's colour is
    /// a token that resolves per theme, a calendar's is a literal value the
    /// user picked. Translating one into the other would invent a colour
    /// nobody chose. Left uninterpreted here — JMAPKit is Foundation-only and
    /// cannot see a colour.
    public var color: String?

    /// Sidebar order, and already applied to `list` — sorting again is
    /// harmless, deriving an order from `id` is not.
    public var sortOrder: Int?

    /// The web sidebar's tick, **published rather than acted on**.
    ///
    /// `CalendarEvent/query` returns events from an invisible calendar just the
    /// same, so this is a display preference to honour client-side. A client
    /// that filtered on it server-side would hide from a phone what its user
    /// chose to hide in a browser, and one that ignored it entirely would show
    /// what they hid.
    public var isVisible: Bool?

    /// Where a new event goes when nobody chose.
    public var isDefault: Bool?

    /// An IANA zone name. The zone an event with no `timeZone` of its own is
    /// local to — which is what an omitted ``EventTimeZone`` on a write means.
    public var timeZone: String?

    /// plMail's extension: what the calendar is *for*. Drives where extracted
    /// events land. A client cannot derive it and a user cannot change it.
    public var role: CalendarRole?

    /// plMail's extension: whether there is a remote behind this calendar.
    ///
    /// **Distinct from writability** — a calendar can mirror a remote and still
    /// accept writes. It is what tells a client that an event created here will
    /// leave the machine, and nothing else. Guess writability from it and the
    /// server answers `forbidden` after the user has typed the whole event.
    public var isSynced: Bool?

    /// The only thing that decides whether this calendar is writable.
    public var myRights: CalendarRights?

    private enum CodingKeys: String, CodingKey {
        case id, name, color, sortOrder, isVisible, isDefault, timeZone, role, isSynced, myRights
    }
}

/// Writability, published as rights rather than as an `isReadOnly` flag —
/// following RFC 8621's Mailbox, because two spellings of *may I write here?*
/// is how one of them ends up not being consulted.
///
/// The first four are all the same gate server-side (`isReadOnly == false`), so
/// a read-only mirror refuses every write and the client can grey the control
/// out instead of discovering it by a `SetError`.
public struct CalendarRights: Hashable, Sendable, Decodable {
    public var mayReadItems: Bool?
    public var mayAddItems: Bool?
    public var mayUpdateAll: Bool?
    public var mayRemoveItems: Bool?

    /// About the **calendar**, not its events, and advisory today because
    /// `Calendar/set` does not exist. False even on the default calendar.
    public var mayDelete: Bool?
}

extension JMAPCalendar {
    /// Whether a create or an edit may be offered here.
    ///
    /// By ``CalendarRights/mayAddItems`` and nothing else — not ``isDefault``,
    /// not ``role``, not ``isSynced``. Absent rights read as not writable,
    /// because a `properties` filter that omitted `myRights` has told us
    /// nothing and offering a write on nothing is the failure this defaults
    /// away from.
    public var isWritable: Bool { myRights?.mayAddItems == true }
}

/// `Calendar.role` — plMail's extension.
///
/// Open on purpose: an unrecognised role must still draw, so a role added on
/// the next server release degrades to ``other(_:)`` rather than failing the
/// whole `Calendar/get` it arrived in.
public enum CalendarRole: Hashable, Sendable, RawRepresentable, Codable {
    case `default`
    case account
    case custom
    case remote
    case other(String)

    public init(rawValue: String) {
        switch rawValue {
        case "default": self = .default
        case "account": self = .account
        case "custom": self = .custom
        case "remote": self = .remote
        default: self = .other(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .default: "default"
        case .account: "account"
        case .custom: "custom"
        case .remote: "remote"
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
