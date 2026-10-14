import Foundation
import JMAPKit

/// Value types for crossing an actor boundary.
///
/// `@Model` classes are not `Sendable` and must never leave the actor that owns
/// their context. When the sync engine needs to *read* something the store
/// knows, it gets one of these instead of a live object.

public struct AccountSnapshot: Hashable, Sendable, Identifiable {
    public var accountKey: String
    public var accountID: AccountID
    /// Whatever the server called it, which may be nothing at all.
    public var name: String
    public var emailState: StateToken?
    public var threadState: StateToken?
    public var mailboxState: StateToken?

    /// The server says this account may not be written to — a shared mailbox,
    /// or one plMail connected read-only.
    public var isReadOnly: Bool = false

    /// When this account last completed a sync, and what stopped it if one
    /// did. Both are already written on every pass; they are carried here so
    /// diagnostics can say *which* mailbox is stale rather than only that
    /// something is. Without them the screen can report the whole server's
    /// last contact and nothing finer, which on a server aggregating five
    /// IMAP accounts is the one number that does not help.
    public var lastSyncedAt: Date?
    public var lastSyncError: String?

    public var id: String { accountKey }

    /// Never empty.
    ///
    /// A JMAP account name is not required to be set, and a real server was
    /// found serving one that wasn't: the result was a blank row in the
    /// "is this the right mailbox?" list during sign-in, and an empty grey
    /// pill on every message from that account. Both read as a rendering bug
    /// rather than as missing data, which is the worst of both — it looks
    /// broken *and* tells you nothing.
    ///
    /// A nameless account is backfilled with its own address when identities
    /// are synced, so this last-resort id should only ever be seen in the
    /// window before that happens.
    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)

        return trimmed.isEmpty ? "Mailbox \(accountID.rawValue)" : trimmed
    }
}

public struct MailboxSnapshot: Hashable, Sendable, Identifiable {
    public var accountKey: String
    public var mailboxID: MailboxID
    public var labelID: LabelID?
    public var name: String
    public var role: MailboxRole?
    /// The parent's *binding* id, or nil for a top-level label. Nil also when
    /// the parent has no binding in this account, which the server reports the
    /// same way rather than pointing at an id the client cannot resolve.
    public var parentID: MailboxID?
    /// The colour the user chose, or nil for "no colour chosen".
    ///
    /// Nil is a third state and not grey: only nil may fall back to the hashed
    /// ``AvatarPalette`` tint, and treating a deliberate `.gray` as unset would
    /// repaint it with something the user did not pick. An unrecognised wire
    /// token also arrives here as nil — the vocabulary can grow, and a label
    /// that fails to parse would vanish from the sidebar.
    public var color: LabelColor?
    public var unreadThreads: Int
    public var totalThreads: Int
    /// The label's visibility toggle in plMail, and **not** a synonym for
    /// "empty" or "unimportant". Archive is created hidden on this server, so
    /// a sidebar that only ever shows subscribed mailboxes leaves a real,
    /// populated label with no way to reach it.
    public var isSubscribed: Bool = true

    /// Whether the server will let this label be renamed and deleted.
    ///
    /// Read from `myRights` rather than inferred from ``role`` being nil. The
    /// two agree today, but the server is the one that decides, and a client
    /// that guesses offers a Rename button that fails on press.
    public var mayRename: Bool = false
    public var mayDelete: Bool = false

    public var id: String { "\(accountKey)#\(mailboxID.rawValue)" }
}

/// One message, as the reader needs it.
public struct MessageSnapshot: Hashable, Sendable, Identifiable {
    public var emailID: String
    public var accountKey: String
    public var blobID: String?
    public var subject: String?
    public var fromName: String?
    public var fromAddress: String?
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    public var receivedAt: Date?
    /// Bare, angle brackets already stripped. Needed to thread a reply.
    public var messageID: String?
    public var references: [String]
    public var preview: String
    public var isSeen: Bool
    public var isFlagged: Bool
    public var isDraft: Bool

    /// Always the server's sanitised HTML. Render on a permanently light
    /// background regardless of theme.
    public var htmlBody: String?
    public var textBody: String?
    /// Whether the body has been fetched at all, as distinct from a message
    /// that genuinely has none.
    public var hasBody: Bool

    public var attachments: [AttachmentSnapshot]
    /// Referenced from the HTML by `cid:` rather than listed to the user.
    public var inlineParts: [AttachmentSnapshot]

    public var id: String { "\(accountKey)#\(emailID)" }

    public var displayName: String {
        if let fromName, fromName.isEmpty == false { return fromName }
        return fromAddress ?? "(unknown sender)"
    }
}

public struct AttachmentSnapshot: Hashable, Sendable, Identifiable {
    public var partID: String
    public var blobID: String
    public var name: String?
    public var type: String
    public var size: Int
    public var cid: String?
    public var isInline: Bool

    public var id: String { partID }

    public var displayName: String {
        guard let name, name.isEmpty == false else { return "Attachment" }
        return name
    }
}

/// A sendable address for one account.
public struct IdentitySnapshot: Hashable, Sendable, Identifiable {
    public var id: IdentityID
    public var name: String?
    public var email: String
    public var textSignature: String?
    /// The signature in the form the server stores it.
    ///
    /// **Empty and nil are different answers and both are ordinary.** Empty is
    /// the stored statement *"this address signs with nothing"*; nil is a row
    /// synced before the column existed, which the next refresh replaces. A
    /// caller deciding whether to append a signature wants
    /// ``hasStoredSignature``, which distinguishes them.
    public var htmlSignature: String?

    /// Whether this identity has a signature with anything in it.
    ///
    /// Whitespace-only counts as nothing: a signature that is one `<br>` is a
    /// signature the user cleared in a rich-text field, and appending it adds a
    /// blank line to every message they send.
    public var hasStoredSignature: Bool {
        let html = htmlSignature ?? ""

        return html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    public var address: EmailAddress { EmailAddress(name: name, email: email) }

    public var displayName: String {
        guard let name, name.isEmpty == false else { return email }

        // An account whose stored address is really its display name — plMail
        // allows it, and a few provider imports produce it — would otherwise
        // render as "Work <Work>", which looks like a formatting bug rather
        // than the data problem it is.
        guard name != email else { return email }

        // An identity with no address at all renders as "Personal <>", which
        // reads as a bug in the app rather than a gap in the account. My own
        // test server returns exactly this for a second account.
        guard email.trimmingCharacters(in: .whitespaces).isEmpty == false else { return name }

        return "\(name) <\(email)>"
    }
}

/// How much of one account's mail is actually on this device.
///
/// One value rather than two lookups, because the answer people want is a
/// single sentence — *"412 messages, back to 3 March"* — and two separately
/// fetched numbers invite a screen that shows a count beside a date taken a
/// second later, after a sync landed between them.
///
/// Counted from the cache and never fetched. Android deleted the button that
/// ran an `Email/query` per account to find the oldest message, because on an
/// account still backfilling the answer it gave silently meant *"oldest
/// fetched so far"* — and a still-backfilling account is exactly the one people
/// open this screen about.
public struct CachedWindowSnapshot: Hashable, Sendable {
    /// Messages held on the device for this account, not messages on the
    /// server. Naming the difference is the screen's job; conflating them is
    /// how "where is my old mail" becomes a bug report.
    public var messageCount: Int

    /// The `receivedAt` of the oldest message cached, or nil when nothing has
    /// synced yet. Nil is an ordinary state — a mailbox connected on the server
    /// a minute ago — and must not be drawn as an error.
    public var oldestReceivedAt: Date?

    public init(messageCount: Int, oldestReceivedAt: Date? = nil) {
        self.messageCount = messageCount
        self.oldestReceivedAt = oldestReceivedAt
    }

    /// True when there is nothing on the device for this account at all.
    public var isEmpty: Bool { messageCount == 0 }
}

/// A feed row taken out optimistically, kept so it can be put back.
public struct RemovedFeedRow: Hashable, Sendable {
    public var feedID: String
    public var sortDate: Date
    public var accountKey: String
    public var threadID: String
    public var emailID: String
}

/// One row of a materialised feed.
public struct FeedEntrySnapshot: Hashable, Sendable {
    public var accountKey: String
    public var threadID: String
    public var emailID: String
    public var sortDate: Date
}

/// Where one account's paging has reached within one feed.
public struct FeedCursorSnapshot: Hashable, Sendable {
    public var lastSortDate: Date?
    public var boundaryIDs: Set<String>
    public var isExhausted: Bool

    public init(
        lastSortDate: Date? = nil,
        boundaryIDs: Set<String> = [],
        isExhausted: Bool = false
    ) {
        self.lastSortDate = lastSortDate
        self.boundaryIDs = boundaryIDs
        self.isExhausted = isExhausted
    }
}

// MARK: - Calendar

/// One calendar, out of the store and safe to hand to the UI.
public struct CalendarSnapshot: Hashable, Sendable, Identifiable {
    public var accountKey: String
    public var calendarID: CalendarID
    public var name: String
    /// `#rrggbb`, and **not** the Tailwind token a label carries. Two
    /// vocabularies, never interchanged.
    public var colorHex: String?
    public var sortOrder: Int = 0
    /// The web sidebar's tick. Published, not obeyed — see `StoredCalendar`.
    public var isVisible: Bool = true
    public var isDefault: Bool = false
    public var timeZone: String?
    public var role: String?
    /// Whether a remote sits behind this calendar. Not the same question as
    /// whether it can be written to.
    public var isSynced: Bool = false

    /// The write gate, straight from `myRights`. The first three are one gate
    /// server-side, so a control disabled from these is a refusal shown before
    /// the press rather than discovered as a `SetError`.
    public var mayAddItems: Bool = false
    public var mayUpdateAll: Bool = false
    public var mayRemoveItems: Bool = false

    public var id: String { "\(accountKey)#\(calendarID.rawValue)" }

    public init(accountKey: String, calendarID: CalendarID, name: String) {
        self.accountKey = accountKey
        self.calendarID = calendarID
        self.name = name
    }
}

/// One event **series** — the unit an editor writes through.
///
/// ``jsCalendarJSON`` rides along because the projected fields are lossy by
/// construction: an imported event carries JSCalendar this build has never
/// heard of, and an editor that reassembled a whole event from these columns
/// would delete it on save.
public struct CalendarEventSnapshot: Hashable, Sendable, Identifiable {
    public var accountKey: String
    public var eventID: CalendarEventID
    public var calendarID: CalendarID?
    /// The JSCalendar `uid`. Half the duplicate-collapse key, because one
    /// meeting legitimately arrives twice on two calendars.
    public var wireUID: String?

    public var title: String
    /// A wall clock, `2026-08-03T10:00:00` — no offset, no `Z`. See
    /// ``timeZoneName`` and ``hasExplicitTimeZone`` for what it is local to.
    public var startLocal: String
    /// ISO 8601, e.g. `PT1H`. A duration rather than an end instant, because
    /// an hour across a DST change is not 3600 seconds of wall clock.
    public var duration: String?
    public var timeZoneName: String?
    /// False means the property was absent — use the calendar's zone. True
    /// with a nil ``timeZoneName`` means explicit JSCalendar floating time,
    /// which is what an all-day event is. Collapsing the two zones every
    /// floating event this client sends back.
    public var hasExplicitTimeZone: Bool = false

    public var showWithoutTime: Bool = false
    public var eventDescription: String?
    /// plMail keeps a place as a label, so there is nothing to geocode.
    public var locationName: String?
    public var status: String?
    /// Published on every event, never writable.
    public var privacy: String?
    /// Server-derived, and not the same claim as a non-empty recurrence rule.
    public var isRecurring: Bool = false
    /// What this was extracted from. **Nil means a person made it.**
    public var kind: String?
    public var source: String?
    public var sequence: Int = 0

    /// The canonical body, verbatim. Patch from it; never rebuild it.
    public var jsCalendarJSON: Data?

    public var id: String { "\(accountKey)#\(eventID.rawValue)" }

    public init(
        accountKey: String,
        eventID: CalendarEventID,
        title: String,
        startLocal: String
    ) {
        self.accountKey = accountKey
        self.eventID = eventID
        self.title = title
        self.startLocal = startLocal
    }
}

/// One materialised occurrence — what a day, week or month view draws.
///
/// Produced only by the server. Expanding a recurrence rule on the device is
/// the one thing forbidden here: the phone and the browser would disagree at a
/// DST boundary, and nothing would report the disagreement.
public struct CalendarOccurrenceSnapshot: Hashable, Sendable, Identifiable {
    public var accountKey: String
    /// The synthetic `<eventId>_<recurrenceId>` id. `CalendarEvent/set`
    /// refuses it — write through ``seriesID``.
    public var occurrenceID: CalendarEventID
    /// From the server's `seriesId`. The only sanctioned route back to
    /// something writable, and never derived by splitting ``occurrenceID``.
    public var seriesID: CalendarEventID
    public var calendarID: CalendarID?

    /// The instance's **original** start, which is its identity within the
    /// series and the key an override is written under — not where it ended up
    /// after one.
    public var recurrenceID: String
    /// The zone ``recurrenceID`` is expressed in: **UTC for a floating
    /// series**, so not the event's own.
    public var recurrenceIDTimeZone: String?

    /// Where the instance actually is.
    public var startLocal: String
    public var duration: String?
    /// Resolved instants, for ordering and placement only. An all-day or
    /// floating occurrence has no instant, so these are a projection against
    /// one zone and must never be compared across devices.
    public var startsAt: Date
    public var endsAt: Date
    public var isAllDay: Bool = false

    public var title: String
    /// `cancelled` here is about **this occurrence**, not the series. Drawing
    /// the series' status instead strikes out every sibling of one cancelled
    /// instance.
    public var status: String?

    public var id: String { "\(accountKey)#\(occurrenceID.rawValue)" }

    public init(
        accountKey: String,
        occurrenceID: CalendarEventID,
        seriesID: CalendarEventID,
        recurrenceID: String,
        startLocal: String,
        startsAt: Date,
        endsAt: Date,
        title: String
    ) {
        self.accountKey = accountKey
        self.occurrenceID = occurrenceID
        self.seriesID = seriesID
        self.recurrenceID = recurrenceID
        self.startLocal = startLocal
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.title = title
    }
}
