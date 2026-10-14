/// An RFC 8621 `Mailbox`.
///
/// A plMail *label binding*, not an IMAP folder. Labels are the user-facing
/// concept and span accounts; a binding is the per-account instance, and that
/// is what has a stable identity inside one JMAP account. IMAP folders exist
/// as sync plumbing and are never surfaced.
public struct Mailbox: Hashable, Sendable, Codable {
    public var id: MailboxID

    /// The user-scoped label this binding materialises. A plMail extension,
    /// not RFC 8621.
    ///
    /// Present so a client can collapse the same label across several accounts
    /// into one sidebar row — matching on ``name`` instead breaks the moment
    /// the label is renamed in one account. It is **not** accepted as input
    /// anywhere; `inMailbox` and `Email/set` take ``id``.
    public var labelID: LabelID?

    /// The **leaf** name. JMAP models hierarchy through ``parentID``, so this
    /// is `"Invoices"`, never `"Work/Invoices"`.
    public var name: String?

    /// The parent's *binding* id, or nil when the parent has no binding in
    /// this account — a child never points at an id the client cannot resolve.
    public var parentID: MailboxID?

    /// The colour the user gave this label, or nil for "no colour chosen".
    ///
    /// A plMail extension, not RFC 8621: `MailboxMapper::toJmap` emits
    /// `label.color`, and without reading it the phone can only draw every
    /// chip in a hashed tint while the web draws the colour the user picked —
    /// which reads as two different label systems rather than one.
    ///
    /// **Nil is a third state and not grey.** Only nil may fall back to a
    /// hashed tint; a label deliberately coloured grey has to stay grey. An
    /// unrecognised token also lands here as nil — see ``init(from:)``.
    public var color: LabelColor?

    public var role: MailboxRole?
    public var sortOrder: Int?

    public var totalEmails: Int?
    public var unreadEmails: Int?
    public var totalThreads: Int?
    public var unreadThreads: Int?

    public var myRights: MailboxRights?

    /// Mirrors the label's visibility toggle. Note **Archive is created hidden
    /// by default** and appears only once the user makes it visible.
    public var isSubscribed: Bool?

    public init(id: MailboxID) {
        self.id = id
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case labelID = "labelId"
        case name
        case parentID = "parentId"
        case color
        case role, sortOrder
        case totalEmails, unreadEmails, totalThreads, unreadThreads
        case myRights, isSubscribed
    }

    /// Hand-written for one reason: ``color`` has to survive a token this
    /// build has never heard of.
    ///
    /// The synthesised decoder would throw `dataCorrupted` on an unknown raw
    /// value, and a `Mailbox` that fails to decode takes the whole
    /// `Mailbox/get` response down with it — so one tenth colour added to the
    /// server would empty every sidebar on every older client. Reading the
    /// token as a string and mapping it through ``LabelColor/init(wire:)``
    /// degrades that to a label drawn in its fallback tint.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(MailboxID.self, forKey: .id)
        labelID = try container.decodeIfPresent(LabelID.self, forKey: .labelID)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        parentID = try container.decodeIfPresent(MailboxID.self, forKey: .parentID)
        color = LabelColor(wire: try container.decodeIfPresent(String.self, forKey: .color))
        role = try container.decodeIfPresent(MailboxRole.self, forKey: .role)
        sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder)
        totalEmails = try container.decodeIfPresent(Int.self, forKey: .totalEmails)
        unreadEmails = try container.decodeIfPresent(Int.self, forKey: .unreadEmails)
        totalThreads = try container.decodeIfPresent(Int.self, forKey: .totalThreads)
        unreadThreads = try container.decodeIfPresent(Int.self, forKey: .unreadThreads)
        myRights = try container.decodeIfPresent(MailboxRights.self, forKey: .myRights)
        isSubscribed = try container.decodeIfPresent(Bool.self, forKey: .isSubscribed)
    }
}

/// The role of a system mailbox.
///
/// An unmapped role degrades to nil server-side and the mailbox still appears,
/// so ``other(_:)`` covers a role this client does not know rather than
/// dropping the mailbox.
public enum MailboxRole: Hashable, Sendable, RawRepresentable, Codable {
    case inbox
    case sent
    case drafts
    /// plMail's Spam.
    case junk
    case trash
    case archive
    /// Where a snoozed conversation waits — a **plMail extension**, not an
    /// IANA special-use. Created lazily the first time something is snoozed,
    /// so an account that never has one is normal rather than broken.
    case snoozed
    case flagged
    case important
    case all
    case other(String)

    public init(rawValue: String) {
        switch rawValue {
        case "inbox": self = .inbox
        case "sent": self = .sent
        case "drafts": self = .drafts
        case "junk": self = .junk
        case "trash": self = .trash
        case "archive": self = .archive
        case "snoozed": self = .snoozed
        case "flagged": self = .flagged
        case "important": self = .important
        case "all": self = .all
        default: self = .other(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .inbox: "inbox"
        case .sent: "sent"
        case .drafts: "drafts"
        case .junk: "junk"
        case .trash: "trash"
        case .archive: "archive"
        case .snoozed: "snoozed"
        case .flagged: "flagged"
        case .important: "important"
        case .all: "all"
        case .other(let value): value
        }
    }

    /// The order the web UI's sidebar uses. Custom labels sort after these,
    /// alphabetically. Mirrored here so both clients agree without the server
    /// having to send it.
    public var sidebarOrder: Int {
        switch self {
        case .inbox: 0
        case .sent: 10
        case .drafts: 20
        case .junk: 30
        case .trash: 40
        case .archive: 50
        case .snoozed: 60
        default: 70
        }
    }
}

/// RFC 8621 `MailboxRights`. System labels — anything with a role — are
/// neither renamable nor deletable; custom labels are fully mutable.
public struct MailboxRights: Hashable, Sendable, Codable {
    public var mayReadItems: Bool?
    public var mayAddItems: Bool?
    public var mayRemoveItems: Bool?
    public var maySetSeen: Bool?
    public var maySetKeywords: Bool?
    public var mayCreateChild: Bool?
    public var mayRename: Bool?
    public var mayDelete: Bool?
    public var maySubmit: Bool?

    public init() {}
}
