import Foundation
import JMAPKit

/// Names one ordered list.
///
/// A feed is a (selection, filter, sort) triple, and its id is what ties the
/// rows in `StoredFeedEntry` to the list on screen. Stable across launches, so
/// a cold start shows the list it showed last time before any network call.
public enum FeedID: Hashable, Sendable {
    /// One role across every account — the unified inbox, and what the app
    /// opens on. There is no server-side cross-account query, so this is a
    /// client-side merge of one query per account.
    case unified(MailboxRole)
    /// One label across every account, tied together by plMail's `labelId`.
    case unifiedLabel(LabelID)
    /// One inbox category across every account — the Gmail tabs.
    ///
    /// **The inbox binding is part of what this selects, not context around
    /// it.** A conversation keeps its category after it is moved to Trash, so a
    /// feed filtered on the category alone would show the bin's promotions
    /// under a heading that claims to be part of the inbox.
    ///
    /// Filtered server-side through `Email/query`'s `threadCategory`, never by
    /// sieving a fetched page: `Email/query` windows by limit, so a client that
    /// filtered locally would draw a nearly-empty Promotions list under a
    /// message saying it had reached the end.
    case category(MessageCategory)
    /// One mailbox in one account.
    case mailbox(accountKey: String, mailboxID: MailboxID)
    /// The results of one search, across every account that can serve it.
    ///
    /// Materialised like any other feed so results page and survive a
    /// backgrounding, but pruned when the search is abandoned — a stored feed
    /// per query typed would grow without bound.
    case searchResults(query: String)

    public var rawValue: String {
        switch self {
        case .unified(let role): "unified:\(role.rawValue)"
        case .unifiedLabel(let label): "label:\(label.rawValue)"
        case .category(let category): "category:\(category.rawValue)"
        case .mailbox(let accountKey, let mailboxID):
            "acct:\(accountKey):mbox:\(mailboxID.rawValue)"
        case .searchResults(let query):
            "search:\(query)"
        }
    }

    /// Reads back an id that was written to a `StoredFeedCursor`.
    ///
    /// The projection (``FeedProjection``) has to reconcile *every* list the
    /// account has paged, and the only record of which those are is a table of
    /// raw strings. Without a way back from the string, a conversation archived
    /// in the browser can be removed from the list that happens to be on screen
    /// and from no other — which is the drift this whole mechanism exists to
    /// stop.
    ///
    /// A search feed round-trips too, so that callers can *recognise* one and
    /// refuse to project into it, rather than failing to parse it and treating
    /// the row as an unknown list.
    ///
    /// `acct:` is split on the **last** `:mbox:` rather than on every colon: an
    /// account key is `server/account` and a host may legitimately carry a
    /// port, so splitting on the first colon would name a server that does not
    /// exist.
    public init?(rawValue: String) {
        if let role = rawValue.dropping(prefix: "unified:") {
            self = .unified(MailboxRole(rawValue: String(role)))
        } else if let label = rawValue.dropping(prefix: "label:") {
            self = .unifiedLabel(LabelID(String(label)))
        } else if let token = rawValue.dropping(prefix: "category:") {
            // A token this build does not know decodes as *no feed* rather
            // than as an unknown list. A stored cursor naming a category that
            // has since been removed from the vocabulary must not come back as
            // something the projection then tries to reconcile.
            guard let category = MessageCategory(wire: String(token)) else { return nil }

            self = .category(category)
        } else if let query = rawValue.dropping(prefix: "search:") {
            self = .searchResults(query: String(query))
        } else if let rest = rawValue.dropping(prefix: "acct:") {
            guard let separator = rest.range(of: ":mbox:", options: .backwards) else {
                return nil
            }

            self = .mailbox(
                accountKey: String(rest[..<separator.lowerBound]),
                mailboxID: MailboxID(String(rest[separator.upperBound...]))
            )
        } else {
            return nil
        }
    }

    /// Whether rows in this feed answer a question rather than describe state.
    ///
    /// Search results must never be projected into: a conversation that gains
    /// the label a sync just wrote does not thereby match a search for
    /// "invoice", and splicing it in would put a row in the list that the query
    /// never returned.
    public var isSearch: Bool {
        if case .searchResults = self { return true }

        return false
    }

    /// The category this list is narrowed to, or nil for a list that is not
    /// narrowed at all.
    ///
    /// Read rather than pattern-matched at four call sites, so "is this a
    /// category list" and "which category" cannot be answered differently by
    /// two of them.
    public var category: MessageCategory? {
        if case .category(let category) = self { return category }

        return nil
    }

    /// Whether this list is the whole inbox, unnarrowed — which is what puts
    /// the category control on screen.
    ///
    /// A single account's inbox mailbox is deliberately **not** included: the
    /// category filter is cross-account by construction, and offering it over
    /// one account's list would be a control that quietly changes which
    /// accounts the list covers.
    public var isUnifiedInbox: Bool {
        if case .unified(.inbox) = self { return true }

        return false
    }

    /// What to show as the list's title.
    ///
    /// A role names itself. A label or a single mailbox does not — the name
    /// lives on the mailbox rows — so the caller passes them in. An untitled
    /// list reads as a rendering fault, so there is always a fallback.
    public func title(mailboxes: [MailboxSnapshot] = []) -> String {
        switch self {
        case .unified(let role):
            return role.displayName

        case .unifiedLabel(let labelID):
            return mailboxes.first { $0.labelID == labelID }?.name ?? "Label"

        case .category(let category):
            return category.displayName

        case .mailbox(let accountKey, let mailboxID):
            let match = mailboxes.first {
                $0.accountKey == accountKey && $0.mailboxID == mailboxID
            }

            return match?.name ?? "Mailbox"

        case .searchResults:
            return "Results"
        }
    }
}

extension MessageCategory {
    /// What the tab is called, localised against **this module's** bundle.
    ///
    /// Beside ``MailboxRole/displayName`` and for the same reason: a
    /// `String(localized:)` without the bundle looks up in the app, misses, and
    /// silently returns the English literal — which reads as a deliberate
    /// untranslated term and is noticed by nobody.
    ///
    /// "Primary" rather than "Inbox": the tab is a slice of the inbox, and
    /// naming it after the whole would leave two rows called Inbox on screen.
    public var displayName: String {
        switch self {
        case .primary: String(localized: "Primary", bundle: .module)
        case .social: String(localized: "Social", bundle: .module)
        case .promotions: String(localized: "Promotions", bundle: .module)
        case .updates: String(localized: "Updates", bundle: .module)
        case .forums: String(localized: "Forums", bundle: .module)
        }
    }

    /// SF Symbol, chosen so the strip is scannable before it is read — five
    /// words of similar length are not.
    public var symbolName: String {
        switch self {
        case .primary: "person.crop.circle"
        case .social: "person.2"
        case .promotions: "tag"
        case .updates: "bell"
        case .forums: "bubble.left.and.bubble.right"
        }
    }
}

extension MailboxRole {
    /// Localised, and against **this module's** bundle.
    ///
    /// These are the most-read words in the app — they name every row in the
    /// sidebar and title every list — and they live in PLMailCore rather than
    /// in the view layer, so the UI module's catalogue never sees them. A
    /// `String(localized:)` without the bundle would look up in the app, miss,
    /// and silently return the English literal.
    ///
    /// `other` is a label the user named themselves; translating it would be
    /// translating their data.
    public var displayName: String {
        switch self {
        case .inbox: String(localized: "Inbox", bundle: .module)
        case .sent: String(localized: "Sent", bundle: .module)
        case .drafts: String(localized: "Drafts", bundle: .module)
        case .junk: String(localized: "Spam", bundle: .module)
        case .trash: String(localized: "Trash", bundle: .module)
        case .archive: String(localized: "Archive", bundle: .module)
        case .snoozed: String(localized: "Snoozed", bundle: .module)
        case .flagged: String(localized: "Starred", bundle: .module)
        case .important: String(localized: "Important", bundle: .module)
        case .all: String(localized: "All mail", bundle: .module)
        case .other(let name): name.capitalized
        }
    }

    /// SF Symbol, chosen to match the vocabulary rather than the plumbing:
    /// these are labels, not folders.
    public var symbolName: String {
        switch self {
        case .inbox: "tray"
        case .sent: "paperplane"
        case .drafts: "doc"
        case .junk: "xmark.bin"
        case .trash: "trash"
        case .archive: "archivebox"
        case .snoozed: "clock"
        case .flagged: "star"
        case .important: "exclamationmark"
        case .all: "envelope"
        case .other: "tag"
        }
    }
}

extension String {
    /// The remainder after `prefix`, or nil when it is not there.
    ///
    /// Written out because `hasPrefix` followed by `dropFirst(n)` is two places
    /// that have to agree on the same literal's length, and they stop agreeing
    /// the first time one of them is edited.
    fileprivate func dropping(prefix: String) -> Substring? {
        guard hasPrefix(prefix) else { return nil }

        return dropFirst(prefix.count)
    }
}
