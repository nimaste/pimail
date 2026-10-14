import Foundation
import JMAPKit

/// One place a message sits, as the notification preferences see it.
///
/// A scope is a *label*, not a message and not an account: someone who turns
/// off a noisy newsletter label expects every message in it to fall silent,
/// including the ones that have not arrived yet. Keying the preference on the
/// message would make that impossible to express.
///
/// ``isNotifiableByDefault`` is carried on the scope rather than looked up
/// later because the default is the whole difference between a mailbox that
/// speaks on first sign-in and one that appears broken. Inbox is on; a label
/// created on the web next month is off, because notifying about it would be
/// noise nobody asked for.
public struct NotifyScope: Hashable, Sendable, Identifiable {
    /// Stable across renames? **No, deliberately.** The key is the label's
    /// path, so renaming a label resets its preference to the default.
    /// Keying on the server's mailbox id would be stable, but the ids are
    /// per-account: the same preference could not then be expressed once for
    /// "Newsletters" across two accounts on one server, which is what people
    /// actually mean when they mute it.
    public var key: String

    /// What the user sees in the settings list. Never the leaf name alone:
    /// two labels called "Receipts" under different parents are two rows that
    /// look identical, and toggling the wrong one is silent.
    public var title: String

    /// Whether a user who has never opened the notification settings hears
    /// about mail in this scope.
    public var isNotifiableByDefault: Bool

    public var id: String { key }

    public init(key: String, title: String, isNotifiableByDefault: Bool) {
        self.key = key
        self.title = title
        self.isNotifiableByDefault = isNotifiableByDefault
    }
}

/// Turning a message's mailbox bindings into the scopes that may speak for it.
public enum NotifyScopes {
    /// Roles that never notify, whatever the preferences say.
    ///
    /// Every one of these is somewhere mail arrives *because of something the
    /// user just did*, or somewhere it was put to be ignored. Without the
    /// exclusion, sending a message rings the sender's own phone the moment
    /// the server files the copy in Sent — which is what the Android client
    /// shipped before this list existed.
    ///
    /// `all` and `archive` are here for a different reason: on this server a
    /// message is bound to Archive *and* Inbox at once, so a rule that
    /// notified per binding would announce archived mail forever.
    public static let neverNotifiableRoles: Set<MailboxRole> = [
        .sent, .drafts, .trash, .junk, .archive, .all, .snoozed,
    ]

    /// The scope key for one mailbox. One definition, because a key spelled
    /// two ways is a preference that saves and never loads.
    public static func key(forPath path: String) -> String { "label:\(path)" }

    /// The full path of a mailbox, parents first, joined by `/`.
    ///
    /// - Parameters:
    ///   - mailbox: The mailbox whose path is wanted.
    ///   - mailboxes: Every mailbox in the account. A parent missing from this
    ///     list ends the walk rather than dropping the label: the server
    ///     reports an unbound parent as nil, and a client that recursed on an
    ///     id it cannot resolve would loop.
    /// - Returns: The path, never empty — a mailbox with no parent is its own
    ///   path.
    public static func path(
        of mailbox: MailboxSnapshot,
        in mailboxes: [MailboxSnapshot]
    ) -> String {
        var byID: [String: MailboxSnapshot] = [:]

        for candidate in mailboxes { byID[candidate.mailboxID.rawValue] = candidate }

        var components = [mailbox.name]
        var seen: Set<String> = [mailbox.mailboxID.rawValue]
        var parentID = mailbox.parentID?.rawValue

        // A cycle is impossible on a well-behaved server and cheap to defend
        // against here; a mailbox tree that pointed at itself would otherwise
        // hang the settings screen rather than showing one wrong row.
        while let id = parentID, seen.contains(id) == false, let parent = byID[id] {
            seen.insert(id)
            components.insert(parent.name, at: 0)
            parentID = parent.parentID?.rawValue
        }

        return components.joined(separator: "/")
    }

    /// Every scope the user may express a preference about, for one account.
    ///
    /// Excludes the never-notifiable roles, so the settings screen cannot
    /// offer a toggle that would do nothing.
    public static func selectable(in mailboxes: [MailboxSnapshot]) -> [NotifyScope] {
        mailboxes
            .filter { mailbox in
                guard let role = mailbox.role else { return true }

                return neverNotifiableRoles.contains(role) == false
            }
            .map { mailbox in
                let path = path(of: mailbox, in: mailboxes)

                return NotifyScope(
                    key: key(forPath: path),
                    title: path,
                    isNotifiableByDefault: mailbox.role == .inbox)
            }
            // De-duplicated by key: two accounts on one server routinely share
            // a label path, and the settings list must show one switch for it
            // rather than two that disagree.
            .reduce(into: [NotifyScope]()) { result, scope in
                if result.contains(where: { $0.key == scope.key }) == false { result.append(scope) }
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// The scopes one message belongs to.
    ///
    /// - Returns: Empty when the message is bound to any never-notifiable
    ///   role, which is a hard veto rather than an absence. A reply that lands
    ///   in both Inbox and Sent is the sender's own copy; announcing it
    ///   because one of its two bindings is notifiable is the bug this
    ///   ordering prevents.
    public static func scopes(
        forMailboxIDs mailboxIDs: Set<String>,
        in mailboxes: [MailboxSnapshot]
    ) -> [NotifyScope] {
        let bound = mailboxes.filter { mailboxIDs.contains($0.mailboxID.rawValue) }

        for mailbox in bound {
            guard let role = mailbox.role else { continue }

            if neverNotifiableRoles.contains(role) { return [] }
        }

        return bound.map { mailbox in
            let path = path(of: mailbox, in: mailboxes)

            return NotifyScope(
                key: key(forPath: path),
                title: path,
                isNotifiableByDefault: mailbox.role == .inbox)
        }
    }
}
