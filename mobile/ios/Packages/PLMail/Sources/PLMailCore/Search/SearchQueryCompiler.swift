import Foundation
import JMAPKit

/// Why an account cannot answer a query at all.
///
/// Carried rather than inferred so the reason can be *said*. An account dropped
/// from the merge shows up as fewer results and no explanation, which reads as
/// the search having quietly lost mail — and for `in:archive` that is the
/// normal case, because plMail creates Archive unsubscribed.
public enum SearchScopeGap: Hashable, Sendable {
    /// No mailbox in this account carries the role `in:` named.
    case role(String)
    /// No label in this account carries the name `label:` named.
    case label(String)
}

/// A query's mailbox narrowing, resolved against one account.
///
/// `in:` and `label:` both compile to `inMailbox`, and both name something that
/// is a *different* id in every account — a role binding for the first, a
/// label binding for the second. Resolving them together, in one type, is what
/// stops the second one from being silently dropped when both are present: a
/// query narrowed by `in:inbox label:receipts` that only honoured the role
/// would return the whole inbox and call it results.
public struct SearchScope: Hashable, Sendable {
    /// Every mailbox binding the query named, in this account.
    public var mailboxIDs: [MailboxID]

    /// Nil when the account can serve the query. Non-nil means skip it, and
    /// say so.
    public var gap: SearchScopeGap?

    /// Whether this account should take part in the search.
    public var canSearch: Bool { gap == nil }

    public init(mailboxIDs: [MailboxID] = [], gap: SearchScopeGap? = nil) {
        self.mailboxIDs = mailboxIDs
        self.gap = gap
    }
}

/// Turns a parsed query into a JMAP filter, per account.
///
/// Per account because `in:` names a *role* and `label:` names a *label*, and
/// both resolve to a different mailbox id in every account — there is no
/// cross-account mailbox. An account that has no mailbox for what was asked is
/// skipped rather than errored on: a Gmail account has no Archive binding until
/// one exists, and refusing the whole search over that would be absurd.
public enum SearchQueryCompiler {
    /// The conditions a query implies, before they are combined.
    ///
    /// Split out from ``filter(for:scope:)`` so an empty query is recognisable
    /// as "no conditions" rather than as a filter that happens to match
    /// everything.
    ///
    /// - Parameters:
    ///   - query: The parsed search string.
    ///   - mailboxIDs: The bindings `in:` and `label:` resolved to here.
    /// - Returns: The conditions, in no particular order.
    public static func conditions(
        for query: ParsedSearchQuery,
        mailboxIDs: [MailboxID]
    ) -> [EmailFilter] {
        var conditions: [EmailFilter] = []

        // Empty values are skipped: `from:` with nothing after it sets an empty
        // string server-side, which matches everything, which is the same as
        // not filtering at all.
        if let from = query.from, from.isEmpty == false { conditions.append(.from(from)) }
        if let to = query.to, to.isEmpty == false { conditions.append(.to(to)) }
        if let cc = query.cc, cc.isEmpty == false { conditions.append(.cc(cc)) }
        if let subject = query.subject, subject.isEmpty == false {
            conditions.append(.subject(subject))
        }

        if query.hasAttachment == true { conditions.append(.hasAttachment(true)) }

        // Backed by the `seen_at` column, exposed as the `$seen` keyword. Both
        // flags set is contradictory and returns nothing — reproduced rather
        // than resolved, so the two clients agree. ``SearchNoticesView`` is
        // what tells the user, since the empty list cannot.
        if query.isUnread == true { conditions.append(.notKeyword(.seen)) }
        if query.isRead == true { conditions.append(.hasKeyword(.seen)) }
        if query.isStarred == true { conditions.append(.hasKeyword(.flagged)) }

        conditions += mailboxIDs.map { .inMailbox($0) }

        // `after` is inclusive and `before` is strict, matching the compiler.
        if let after = query.after { conditions.append(.after(UTCDate(after))) }
        if let before = query.before { conditions.append(.before(UTCDate(before))) }

        if query.freeText.isEmpty == false {
            // Real full-text search: a Postgres tsvector matched with
            // websearch_to_tsquery, so this is stemmed and ranked rather than
            // a substring scan — and quoted runs are phrases.
            conditions.append(.text(query.freeText))
        }

        return conditions
    }

    /// The filter for one account, or nil when the query selects nothing here.
    public static func filter(
        for query: ParsedSearchQuery,
        scope: SearchScope
    ) -> EmailFilter? {
        guard scope.canSearch else { return nil }

        let conditions = conditions(for: query, mailboxIDs: scope.mailboxIDs)

        guard conditions.isEmpty == false else { return nil }
        guard conditions.count > 1 else { return conditions[0] }

        return .and(conditions)
    }

    /// What one account can narrow to, and why it cannot take part if it can't.
    public static func scope(
        for query: ParsedSearchQuery,
        mailboxes: [MailboxSnapshot]
    ) -> SearchScope {
        var ids: [MailboxID] = []

        if let role = query.mailboxRole {
            guard let id = binding(forRole: role, in: mailboxes) else {
                return SearchScope(gap: .role(role))
            }

            ids.append(id)
        }

        if let label = query.label, label.isEmpty == false {
            guard let id = binding(forLabel: label, in: mailboxes) else {
                return SearchScope(gap: .label(label))
            }

            ids.append(id)
        }

        return SearchScope(mailboxIDs: ids)
    }

    /// Whether this account can serve the query at all.
    ///
    /// A query naming `in:archive` means nothing in an account with no Archive
    /// binding, and including it would return that account's whole mailbox.
    /// `label:` has exactly the same problem for exactly the same reason.
    public static func canSearch(
        _ query: ParsedSearchQuery,
        mailboxes: [MailboxSnapshot]
    ) -> Bool {
        scope(for: query, mailboxes: mailboxes).canSearch
    }

    /// The mailbox `in:` names within one account.
    ///
    /// Only `in:`. `label:` also compiles to `inMailbox` but can be present
    /// alongside it, so anything that needs both must ask for a ``SearchScope``
    /// rather than a single id.
    public static func mailboxID(
        for query: ParsedSearchQuery,
        mailboxes: [MailboxSnapshot]
    ) -> MailboxID? {
        guard let role = query.mailboxRole else { return nil }

        return binding(forRole: role, in: mailboxes)
    }

    /// The single-mailbox entry point, kept for callers that predate
    /// ``SearchScope``.
    ///
    /// **Refuses a query carrying `label:`**, rather than compiling one without
    /// the label condition. A filter that quietly drops a narrowing the user
    /// asked for returns a page of everything and looks exactly like a search
    /// that was ignored; nothing at all is the honest answer until the caller
    /// moves to ``filter(for:scope:)``.
    public static func filter(
        for query: ParsedSearchQuery,
        mailboxID: MailboxID?
    ) -> EmailFilter? {
        guard query.label?.isEmpty ?? true else { return nil }

        return filter(
            for: query, scope: SearchScope(mailboxIDs: mailboxID.map { [$0] } ?? []))
    }

    /// The conditions for a single resolved mailbox. See
    /// ``filter(for:mailboxID:)`` for why this shape still exists.
    public static func conditions(
        for query: ParsedSearchQuery,
        mailboxID: MailboxID?
    ) -> [EmailFilter] {
        conditions(for: query, mailboxIDs: mailboxID.map { [$0] } ?? [])
    }

    // MARK: - Resolution

    /// The iOS spelling of a server role name.
    ///
    /// The two vocabularies differ in exactly one place and it is the one
    /// people type: the server's role is `spam`, this client's is `junk`.
    /// Keeping the translation here means ``ParsedSearchQuery/mailboxRole`` can
    /// stay readable against the PHP DTO it mirrors.
    static func mailboxRole(forServerRole role: String) -> MailboxRole? {
        switch role {
        case "inbox": .inbox
        case "sent": .sent
        case "drafts": .drafts
        case "trash": .trash
        case "spam": .junk
        case "archive": .archive
        case "snoozed": .snoozed
        default: nil
        }
    }

    private static func binding(
        forRole role: String, in mailboxes: [MailboxSnapshot]
    ) -> MailboxID? {
        guard let wanted = mailboxRole(forServerRole: role) else { return nil }

        return mailboxes.first { $0.role == wanted }?.mailboxID
    }

    /// A label binding by leaf name, matching the server's
    /// `LOWER(lbl.name) = :labelName AND lbl.role IS NULL`.
    ///
    /// Exact and case-insensitive, and role mailboxes are excluded — so
    /// `label:inbox` finds nothing here just as it finds nothing there. Folded
    /// with `caseInsensitiveCompare` rather than `lowercased()` on both sides
    /// so a Turkish locale cannot turn "I" into something Postgres would not.
    private static func binding(
        forLabel name: String, in mailboxes: [MailboxSnapshot]
    ) -> MailboxID? {
        mailboxes.first {
            $0.role == nil && $0.name.caseInsensitiveCompare(name) == .orderedSame
        }?.mailboxID
    }
}

extension FeedID {
    /// A feed for one search.
    ///
    /// Keyed on the query text so two different searches cannot share rows,
    /// and so returning to the same search shows its results immediately.
    public static func search(_ raw: String) -> FeedID {
        .searchResults(query: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}
