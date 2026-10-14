import Foundation
import JMAPKit
import SwiftData

// MARK: - The rule this whole schema depends on
//
// EVERYTHING HERE IS A CACHE. Every row is reconstructible from the server, and
// nothing may be stored here that isn't. The only irreplaceable state the app
// holds is the server address and credential, which live in the Keychain, plus
// local preferences in UserDefaults.
//
// That is a constraint, not an observation. It buys the recovery strategy in
// `MailStack`: on any migration or corruption failure, delete the store and
// re-sync. Which means no custom migration stage ever has to be written for
// cache data — and it stays true only as long as nobody adds a column holding
// something the server doesn't know about. If you find yourself wanting to,
// that is the signal to ask for a server change instead.
//
// Two things the app holds are irreplaceable, and both are kept out of here on
// purpose: unsent mail in `Compose/Outbox.swift` and mail actions taken while
// the server was unreachable in `Sync/ActionQueue.swift`, each under
// Application Support. Neither is reconstructible from anything, so a schema
// change that deleted the store would be data loss rather than a re-sync.

public enum SchemaV1: VersionedSchema {
    public static let versionIdentifier = Schema.Version(1, 0, 0)

    public static var models: [any PersistentModel.Type] {
        [
            StoredAccount.self,
            StoredMailbox.self,
            StoredThread.self,
            StoredEmail.self,
            StoredEmailBody.self,
            StoredAttachment.self,
            StoredFeedEntry.self,
            StoredFeedCursor.self,
            StoredIdentity.self,
            StoredCalendar.self,
            StoredCalendarEvent.self,
            StoredCalendarOccurrence.self,
        ]
    }
}

/// Identity across the store.
///
/// JMAP ids are unique only *within* an account, and one login reaches several
/// accounts, so every row is keyed by a composite. `accountKey` is the
/// server-plus-account prefix; `uid` appends the object's own id.
public enum StoreKey {
    public static func account(server: String, account: AccountID) -> String {
        "\(server)/\(account.rawValue)"
    }

    public static func object(accountKey: String, id: String) -> String {
        "\(accountKey)#\(id)"
    }
}

// MARK: - Account

@Model
public final class StoredAccount {
    #Unique<StoredAccount>([\.uid])

    public var uid: String = ""
    public var serverID: String = ""
    /// The JMAP account id. Always a string on the wire.
    public var accountID: String = ""
    /// The mail address, as the server reports it.
    public var name: String = ""
    public var isPersonal: Bool = true
    public var isReadOnly: Bool = false
    public var sortIndex: Int = 0

    // One sync cursor per JMAP object type. `"0"` is always answerable, so a
    // fresh account starts there rather than at nil-meaning-everything.
    public var emailState: String?
    public var threadState: String?
    public var mailboxState: String?

    public var lastSyncedAt: Date?
    /// The last failure, kept so the diagnostics screen can show it. Users
    /// self-host: when something breaks they are the one who has to fix it.
    public var lastSyncError: String?

    public init(uid: String, serverID: String, accountID: String, name: String) {
        self.uid = uid
        self.serverID = serverID
        self.accountID = accountID
        self.name = name
    }

    public var accountKey: String { uid }
}

// MARK: - Mailbox

@Model
public final class StoredMailbox {
    #Unique<StoredMailbox>([\.uid])

    public var uid: String = ""
    public var accountKey: String = ""

    /// The JMAP Mailbox id — a per-account label *binding* id.
    public var mailboxID: String = ""
    /// The user-scoped label id, from plMail's `labelId` extension. Distinct
    /// from ``mailboxID`` and never accepted as input anywhere; it exists so
    /// one label across several accounts can collapse into one sidebar row.
    public var labelID: String?

    /// Leaf name only. Hierarchy is expressed through ``parentID``.
    ///
    /// Two labels called `Q1`, one under `Work` and one under `Personal`, are
    /// two identical rows to anything that reads this alone — which is why
    /// ``parentID`` has to be walked before a name is drawn.
    public var name: String = ""
    /// The parent's *binding* id, or nil for a top-level label.
    ///
    /// Nil also when the parent has no binding in this account, which is how
    /// the server reports it rather than pointing at an id the client cannot
    /// resolve — so a nil here is never an invitation to go looking.
    public var parentID: String?
    /// The label's chosen colour, as one of nine closed wire tokens.
    ///
    /// Stored as the raw token rather than as ``JMAPKit/LabelColor`` because a
    /// server that adds a tenth token must still be storable: parsing on read
    /// lets an unknown one degrade to "no colour", where a typed column would
    /// make the row undecodable and drop the label out of the sidebar
    /// entirely.
    ///
    /// **Nil is "no colour chosen", which is not grey.** Only nil may fall
    /// back to the hashed avatar tint.
    public var color: String?
    public var role: String?
    public var sortOrder: Int = 0

    public var totalEmails: Int = 0
    public var unreadEmails: Int = 0
    public var totalThreads: Int = 0
    public var unreadThreads: Int = 0

    public var isSubscribed: Bool = true
    public var mayRename: Bool = false
    public var mayDelete: Bool = false

    public init(uid: String, accountKey: String, mailboxID: String, name: String) {
        self.uid = uid
        self.accountKey = accountKey
        self.mailboxID = mailboxID
        self.name = name
    }
}

// MARK: - Thread

@Model
public final class StoredThread {
    #Unique<StoredThread>([\.uid])

    public var uid: String = ""
    public var accountKey: String = ""
    public var threadID: String = ""
    public var emailIDs: [String] = []

    // Denormalised list-row fields, recomputed on every write.
    //
    // Load-bearing, not an optimisation: the unified inbox sorts across
    // accounts on `latestReceivedAt` with no joins and no faults. Recomputing
    // these on write is cheap; deriving them on read for fifty rows at 120fps
    // is not.
    public var latestReceivedAt: Date = Date.distantPast
    public var subject: String?
    public var participantsSummary: String = ""
    /// The newest sender's address, kept beside the display name because the
    /// list draws an avatar whose colour is hashed from it. Hashing the display
    /// name instead would recolour the same person whenever they changed how
    /// their client spells their name.
    public var participantsAddress: String?
    public var snippet: String = ""
    public var messageCount: Int = 1
    public var isUnread: Bool = false
    public var isFlagged: Bool = false
    public var hasAttachment: Bool = false
    /// Whether the newest message is an unsent draft. Drives where a tap goes:
    /// a draft opens the composer, not the reader, which is also what the web
    /// UI does.
    public var isDraft: Bool = false
    /// The newest message's id, so a draft row can open exactly that message
    /// without the list having to reason about thread ordering.
    public var newestEmailID: String?
    /// When a snoozed conversation is due back, from plMail's Thread
    /// extension. The server nils an elapsed snooze, so a value here is always
    /// still pending — nothing has to re-check the clock to know that.
    public var snoozedUntil: Date?
    /// The classifier's tab for this conversation, as a raw wire token.
    ///
    /// **Nil means no tab, not Primary.** A conversation the classifier never
    /// saw belongs under no heading at all; folding it into Primary would put
    /// mail on the phone's Primary tab that the web UI's does not have, and
    /// the two clients would then disagree about the same mailbox. Parse
    /// through ``JMAPKit/MessageCategory``, which maps an unknown token to nil
    /// for the same reason.
    ///
    /// Denormalised here so the sidebar can decide whether this server
    /// classifies anything at all without issuing a query — five empty tabs on
    /// an install with no classifier is worse than none.
    public var category: String?
    /// Never displayed to this user, and arrived inside the server's 24-hour
    /// window.
    ///
    /// Written from `Thread/get`, never computed. The window is applied
    /// server-side against one clock reading per response, so two threads in
    /// one answer cannot straddle the boundary; re-deriving it from
    /// ``latestReceivedAt`` here would reintroduce exactly that.
    ///
    /// **New is not unread and the two are allowed to disagree**: a
    /// conversation read on a laptop is still new to a client that has never
    /// drawn its row.
    public var isNew: Bool = false

    public init(uid: String, accountKey: String, threadID: String) {
        self.uid = uid
        self.accountKey = accountKey
        self.threadID = threadID
    }
}

// MARK: - Email

@Model
public final class StoredEmail {
    #Unique<StoredEmail>([\.uid])

    public var uid: String = ""
    public var accountKey: String = ""
    public var emailID: String = ""
    public var threadID: String?
    public var blobID: String?

    /// Nullable to match the wire type. The server falls back through
    /// `receivedAt ?? sentAt ?? createdAt` so it is in practice always set —
    /// but any sort must put nils last rather than assume.
    public var receivedAt: Date?
    public var sentAt: Date?

    public var subject: String?
    /// Bare header ids, brackets stripped. Kept because a reply that omits
    /// them starts a new conversation instead of continuing one.
    public var messageID: String?
    public var references: [String] = []
    public var fromName: String?
    public var fromAddress: String?
    /// `[EmailAddress]` as JSON. Recipients are shown but never queried on, so
    /// a blob costs nothing and keeps the schema from growing three tables.
    public var toJSON: Data?
    public var ccJSON: Data?
    public var bccJSON: Data?

    public var preview: String = ""
    public var size: Int = 0

    public var isSeen: Bool = false
    public var isFlagged: Bool = false
    public var isDraft: Bool = false
    public var isAnswered: Bool = false
    public var hasAttachment: Bool = false

    /// Mailbox (binding) ids this message is in.
    public var mailboxIDs: [String] = []

    /// Separate model so list-driving fetches never fault a 400KB HTML string
    /// into memory, and so bodies can be evicted without touching this row.
    @Relationship(deleteRule: .cascade)
    public var body: StoredEmailBody?

    @Relationship(deleteRule: .cascade)
    public var attachments: [StoredAttachment] = []

    public init(uid: String, accountKey: String, emailID: String) {
        self.uid = uid
        self.accountKey = accountKey
        self.emailID = emailID
    }
}

@Model
public final class StoredEmailBody {
    #Unique<StoredEmailBody>([\.uid])

    public var uid: String = ""
    public var textBody: String?
    /// Always the server's sanitised HTML. Render it on a permanently light
    /// background regardless of theme.
    public var htmlBody: String?
    public var fetchedAt: Date = Date.distantPast

    public init(uid: String) {
        self.uid = uid
    }
}

@Model
public final class StoredAttachment {
    #Unique<StoredAttachment>([\.uid])

    public var uid: String = ""
    public var accountKey: String = ""
    public var partID: String = ""
    /// Opaque and namespaced server-side. Never parsed.
    public var blobID: String = ""
    public var name: String?
    public var type: String = "application/octet-stream"
    public var size: Int = 0
    public var cid: String?
    public var isInline: Bool = false

    public init(uid: String, accountKey: String, partID: String, blobID: String) {
        self.uid = uid
        self.accountKey = accountKey
        self.partID = partID
        self.blobID = blobID
    }
}

// MARK: - Feed

/// One row of a materialised, ordered list.
///
/// Not the same thing as "every thread I have cached". A `@Query` over
/// ``StoredThread`` sorted by date would show every thread from every mailbox;
/// this table is the persisted answer to *this particular list, as far down as
/// I have paged*, which is what makes the list instant on cold launch and keeps
/// scroll position stable across a refresh.
@Model
public final class StoredFeedEntry {
    #Unique<StoredFeedEntry>([\.uid])

    public var uid: String = ""
    public var feedID: String = ""
    public var sortDate: Date = Date.distantPast
    public var accountKey: String = ""
    public var threadID: String = ""
    /// The newest email in the thread — the one the row renders from.
    public var emailID: String = ""

    public init(
        uid: String, feedID: String, sortDate: Date, accountKey: String,
        threadID: String, emailID: String
    ) {
        self.uid = uid
        self.feedID = feedID
        self.sortDate = sortDate
        self.accountKey = accountKey
        self.threadID = threadID
        self.emailID = emailID
    }
}

/// How deep one account has been paged within one feed.
@Model
public final class StoredFeedCursor {
    #Unique<StoredFeedCursor>([\.uid])

    public var uid: String = ""
    public var feedID: String = ""
    public var accountKey: String = ""

    /// The `receivedAt` of the last row emitted. The next page asks for
    /// everything strictly before it.
    public var lastSortDate: Date?
    /// Ids already emitted at exactly ``lastSortDate``.
    ///
    /// `before` is a strict `<`, so messages sharing one second across a page
    /// boundary would be dropped. The next page asks for `before:
    /// lastSortDate + 1s` and filters these out.
    public var boundaryIDs: [String] = []
    public var isExhausted: Bool = false

    public init(uid: String, feedID: String, accountKey: String) {
        self.uid = uid
        self.feedID = feedID
        self.accountKey = accountKey
    }
}

// MARK: - Identity

/// Populated now, unused until compose — one extra call, and it tells the UI
/// which addresses are "me" so a participant list can elide the user.
@Model
public final class StoredIdentity {
    #Unique<StoredIdentity>([\.uid])

    public var uid: String = ""
    public var accountKey: String = ""
    public var identityID: String = ""
    public var name: String?
    public var email: String = ""
    /// The plain-text signature, as the server holds it. Stored because the
    /// composer needs it the moment it opens, and fetching identities is a
    /// round trip a composer should not wait on.
    public var textSignature: String?
    /// The same signature as HTML, which is the form the server actually
    /// stores — `textSignature` is derived from it, not stored beside it.
    ///
    /// Kept because a composer that only had the text form would have to
    /// re-flatten the signature on every From change, and because the settings
    /// screen edits *this* value: writing back a round trip through plain text
    /// would quietly strip a signature's links and formatting the first time
    /// anyone opened the editor and pressed Save.
    ///
    /// **Empty is not nil.** An empty string is the server's stored statement
    /// *"this address signs with nothing"*, which on an account that has its
    /// own signature is different from having said nothing; nil is only ever
    /// "this row predates the column" and re-syncs away.
    public var htmlSignature: String?

    public init(uid: String, accountKey: String, identityID: String, email: String) {
        self.uid = uid
        self.accountKey = accountKey
        self.identityID = identityID
        self.email = email
    }
}

// MARK: - Calendar
//
// Shapes only. Nothing writes these yet; they are here so the calendar feature
// lands without a second schema change, since any schema change deletes the
// whole store and re-syncs every mailbox on the device.
//
// All three are cache in the strict sense the banner above means: the server
// materialises occurrences and the client never expands a recurrence rule
// itself, so everything here can be re-fetched and nothing here is an answer
// only this device holds.

/// One calendar, as `Calendar/get` publishes it.
///
/// Calendars come from exactly one account — a plMail calendar is user-scoped
/// with no per-account binding — so ``accountKey`` records *which* account that
/// was rather than partitioning anything. A client that guessed the account
/// instead of finding the one whose `accountCapabilities` carry the calendars
/// URN gets `accountNotSupportedByMethod` on every call.
@Model
public final class StoredCalendar {
    #Unique<StoredCalendar>([\.uid])

    public var uid: String = ""
    public var accountKey: String = ""
    public var calendarID: String = ""

    public var name: String = ""
    /// **`#rrggbb` hex**, and deliberately not the Tailwind token
    /// ``StoredMailbox/color`` carries. The two are different vocabularies in
    /// the server's database, and translating one into the other would invent
    /// a colour the user never picked.
    public var colorHex: String?
    public var sortOrder: Int = 0
    /// The web sidebar's tick, **published rather than acted on**. Filtering
    /// events by it would hide from the phone what its user chose to collapse
    /// in a browser, which is a different question from what they want to see
    /// here.
    public var isVisible: Bool = true
    /// Where a new event goes when nobody chose.
    public var isDefault: Bool = false
    /// IANA name: the zone an event carrying no `timeZone` of its own is local
    /// to. Not the device's zone, and substituting the device's is what puts
    /// an imported event an hour out for anyone who travels.
    public var timeZone: String?
    /// What the calendar is *for*, as a raw token. A client cannot derive it
    /// and a user cannot change it, so it is stored rather than inferred.
    public var role: String?
    /// Whether there is a remote behind this calendar. **Distinct from
    /// writability** — a calendar can mirror a remote and still accept writes
    /// — and it is the only thing that tells the user an event created here
    /// will leave the machine.
    public var isSynced: Bool = false

    // The `myRights` gate, stored as the server sends it rather than reduced
    // to one `isReadOnly` flag. Two spellings of "may I write here?" is how one
    // of them ends up not being consulted; and a control greyed out from these
    // is a refusal the user sees before pressing rather than as a `SetError`.
    public var mayReadItems: Bool = true
    public var mayAddItems: Bool = false
    public var mayUpdateAll: Bool = false
    public var mayRemoveItems: Bool = false
    /// About the *calendar*, not its events, and advisory today because
    /// `Calendar/set` does not exist.
    public var mayDelete: Bool = false

    public init(uid: String, accountKey: String, calendarID: String, name: String) {
        self.uid = uid
        self.accountKey = accountKey
        self.calendarID = calendarID
        self.name = name
    }
}

/// One event **series** — the unit a form edits and the only unit
/// `CalendarEvent/set` accepts.
///
/// Kept separately from ``StoredCalendarOccurrence`` because the two answer
/// different questions and share almost no fields: a series is what a rule
/// says, an occurrence is where the server put it. Collapsing them would mean
/// either re-expanding a rule on the device — which is how a phone and a
/// browser end up disagreeing at a DST boundary — or losing the ability to
/// edit anything that repeats.
@Model
public final class StoredCalendarEvent {
    #Unique<StoredCalendarEvent>([\.uid])

    public var uid: String = ""
    public var accountKey: String = ""
    /// The series' `calendar_event` row id.
    public var eventID: String = ""
    public var calendarID: String?

    /// The JSCalendar `uid`, stable across servers where ``eventID`` is not.
    ///
    /// Load-bearing rather than informational: one meeting legitimately
    /// reaches plMail twice — extracted from an invitation onto the account's
    /// calendar and mirrored from a provider onto a connected one — and both
    /// rows are correct. This is half the key the duplicate collapse groups on.
    public var wireUID: String?

    public var title: String = ""
    /// A JSCalendar `LocalDateTime`: `2026-08-03T10:00:00`, **no offset and no
    /// trailing `Z`**. Stored as the string the server sent, because parsing
    /// it as UTC shifts every event by the reader's own offset and the damage
    /// is invisible until somebody travels.
    public var startLocal: String = ""
    /// ISO 8601 duration — `PT1H`, `P1D`. Stored rather than an end instant,
    /// because a duration across a DST change is not a fixed number of seconds.
    public var duration: String?

    /// The IANA zone name, when there is one. See ``hasExplicitTimeZone``.
    public var timeZoneName: String?
    /// Whether the wire carried a `timeZone` property at all.
    ///
    /// The wire has **three** states and an optional string only models two.
    /// Absent means "use the calendar's zone"; an explicit null is JSCalendar
    /// floating time, which is what every all-day event is; a name is a name.
    /// Collapsing the first two zones every floating event the client sends
    /// back, turning a birthday into something that moves when the user
    /// travels. So: `hasExplicitTimeZone == false` is absent,
    /// `true` with a nil ``timeZoneName`` is floating.
    public var hasExplicitTimeZone: Bool = false

    /// All-day. On the wire this is emitted only when true.
    public var showWithoutTime: Bool = false
    public var eventDescription: String?
    /// plMail stores a place as a **label**, not coordinates, so there is
    /// nothing to put on a map and nothing to geocode.
    public var locationName: String?

    /// `confirmed`, `tentative` or `cancelled`, as a raw token so a value this
    /// build has not heard of is still stored and still drawable.
    public var status: String?
    /// Published on every event and **not writable**. Stored so the editor can
    /// show it greyed rather than offering a control whose save is refused.
    public var privacy: String?

    /// **Derived server-side, and not the same claim as a non-empty
    /// recurrence rule.** A rule the server could not convert is kept verbatim
    /// and expands to a single occurrence; the two disagree exactly on the
    /// imported events a user is most likely to notice. Read this, never infer
    /// it.
    public var isRecurring: Bool = false

    /// What this was extracted from — `flight`, `lodging`, `delivery` and so
    /// on. **Nil means a person made it**, which is the server's own
    /// `isExtracted()` test, so nil is a real answer rather than missing data.
    public var kind: String?
    /// Where the event came from: `manual`, `ics`, `llm`, `remoteSync`, … Note
    /// the camelCase wire values, and that `llm` is the one source the server
    /// marks untrusted.
    public var source: String?
    public var sequence: Int = 0
    /// UTC instants, `Y-m-d\TH:i:s\Z` — **unlike ``startLocal``**, which is a
    /// wall clock. The two look similar enough on the wire that swapping the
    /// parsers is easy and silent.
    public var createdAt: Date?
    public var updatedAt: Date?

    /// The canonical JSCalendar body, verbatim.
    ///
    /// Events carry arbitrary JSCalendar — an import can bring links, virtual
    /// locations and anything else the format defines — so the projected
    /// columns above are a drawing convenience and this is the truth. A round
    /// trip through a typed Swift model is lossy, and writing one back
    /// wholesale silently deletes whatever this build had not heard of. Send
    /// only the properties the user actually changed.
    public var jsCalendarJSON: Data?

    public init(uid: String, accountKey: String, eventID: String) {
        self.uid = uid
        self.accountKey = accountKey
        self.eventID = eventID
    }
}

/// One materialised occurrence, as an expanded `CalendarEvent/query` returns
/// it. What a day, week or month view actually draws.
///
/// **The server expands recurrences and this client never does.** Reconstructing
/// occurrences from a rule locally is the one thing forbidden here: the phone
/// and the browser would disagree at a DST boundary, and the disagreement would
/// be a meeting an hour out with nothing anywhere reporting it.
@Model
public final class StoredCalendarOccurrence {
    #Unique<StoredCalendarOccurrence>([\.uid])

    /// Keyed by the **synthetic occurrence id**, `<eventId>_<recurrenceId>`,
    /// not by series-plus-day.
    ///
    /// A standup at 09:00 and its rescheduled twin at 16:00 are two
    /// occurrences of one series on one day; a key of series-plus-date would
    /// silently keep one and drop the other, and a calendar quietly losing a
    /// meeting is the worst shape a calendar bug takes. Two occurrences of one
    /// series therefore share a day here by construction.
    public var uid: String = ""
    public var accountKey: String = ""
    /// The synthetic instance id. `CalendarEvent/set` **refuses** it; writes go
    /// through ``seriesID``.
    public var occurrenceID: String = ""
    /// The series this belongs to, taken from the server's `seriesId`
    /// property. The only sanctioned route from an occurrence back to
    /// something writable — never string surgery on ``occurrenceID``.
    public var seriesID: String = ""
    public var calendarID: String?

    /// The instance's **original** start as a `LocalDateTime` — its identity
    /// within the series, and the key `recurrenceOverrides` is written under.
    /// Not where the occurrence actually is: an override moves the second and
    /// leaves this alone.
    public var recurrenceID: String = ""
    /// The zone ``recurrenceID`` is expressed in, which is **UTC for a
    /// floating series** and therefore not the event's own zone. Reading it as
    /// the event's is how an override stops matching the occurrence it was
    /// written for.
    public var recurrenceIDTimeZone: String?

    /// Where the instance actually is, read off the materialised row.
    public var startLocal: String = ""
    public var duration: String?
    /// The resolved instant, for ordering and for windowed fetches.
    ///
    /// A projection, not the truth — an all-day or floating occurrence has no
    /// instant at all, and this holds its wall clock resolved against the
    /// calendar's zone purely so one sort can order the day. Never compare it
    /// against another device's.
    public var startsAt: Date = Date.distantPast
    public var endsAt: Date = Date.distantPast
    /// Local calendar day, `yyyy-MM-dd`, so a day view is one indexed read
    /// rather than a scan with date arithmetic in the predicate. Not unique:
    /// see ``uid``.
    public var dayKey: String = ""
    public var isAllDay: Bool = false

    /// Denormalised from the series so a grid can draw a month without
    /// faulting every event behind it.
    public var title: String = ""
    /// **Overwritten to `cancelled` when this occurrence is cancelled, which is
    /// not the series' status.** Reading the series' instead draws a struck-out
    /// row for every sibling of a single cancelled instance.
    public var status: String?

    public init(
        uid: String, accountKey: String, occurrenceID: String, seriesID: String
    ) {
        self.uid = uid
        self.accountKey = accountKey
        self.occurrenceID = occurrenceID
        self.seriesID = seriesID
    }
}
