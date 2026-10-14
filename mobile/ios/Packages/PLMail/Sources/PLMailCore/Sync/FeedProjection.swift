import Foundation
import JMAPKit

/// One row to add to, or remove from, one list.
///
/// A value rather than a direct write so a whole sync batch reaches the store
/// as one transaction: ``SyncStore`` is a `@ModelActor`, and saving per changed
/// conversation would turn a page of fifty messages into fifty saves.
public struct FeedProjectionChange: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// The conversation no longer belongs here — archived in the browser,
        /// or moved by a rule.
        case remove
        /// It belongs here and the list has paged deep enough to hold it.
        case insert(sortDate: Date, emailID: String)
    }

    public var feedID: String
    public var accountKey: String
    public var threadID: String
    public var kind: Kind

    public init(feedID: String, accountKey: String, threadID: String, kind: Kind) {
        self.feedID = feedID
        self.accountKey = accountKey
        self.threadID = threadID
        self.kind = kind
    }
}

/// Keeps every cached list correct after a sync, not only the one on screen.
///
/// Delta sync updates *objects*; the feed tables hold *ordering*. Without a
/// reconciliation step between the two, a conversation archived in the browser
/// stays on the iOS inbox sixty rows down until that account is re-paged, and a
/// conversation labelled `Work` never appears in the `Work` list until that
/// list is opened. Every list other than the visible one drifts, silently, and
/// the user's own gesture in another client looks like it was ignored.
///
/// Pure rules, deliberately: the decisions here are the ones that go wrong, and
/// they are worth testing without a store, a server or a clock.
public enum FeedProjection {
    /// Whether a conversation belongs in a feed, given the mailboxes its
    /// messages are in.
    ///
    /// Returns nil when the question does not apply — a search feed, or a feed
    /// belonging to another account — which the caller must treat as "leave
    /// alone" rather than as "remove". Removing on a nil is how a projection
    /// empties every list it does not understand.
    /// - Parameters:
    ///   - feed: The list being asked about.
    ///   - mailboxIDs: The union of the mailboxes this conversation's messages
    ///     are in.
    ///   - accountKey: Which account the conversation belongs to.
    ///   - mailboxes: That account's mailbox bindings, for resolving a role.
    ///   - category: The conversation's resolved category, or nil when the
    ///     classifier never saw it. **Nil is not Primary** — an unclassified
    ///     conversation belongs to no tab at all, which is what the server's own
    ///     inbox query does. Folding it into Primary would put mail on the
    ///     phone's Primary tab that the browser's does not have.
    /// - Returns: Whether the conversation belongs in `feed`, or nil when the
    ///   question does not apply — which the caller must treat as "leave alone"
    ///   rather than as "remove".
    public static func belongs(
        in feed: FeedID,
        mailboxIDs: Set<String>,
        accountKey: String,
        mailboxes: [MailboxSnapshot],
        category: MessageCategory? = nil
    ) -> Bool? {
        switch feed {
        case .searchResults:
            // Rows here answer a question, not a state. A conversation that
            // gains a label does not thereby match a search for "invoice".
            return nil

        case .unified(let role):
            guard
                let binding = mailboxes.first(where: {
                    $0.accountKey == accountKey && $0.role == role
                })
            else {
                // This account has no binding for the role, so it contributes
                // no rows to that list and never did. Saying "does not belong"
                // would be true but useless, and inviting a delete of rows this
                // account cannot own.
                return nil
            }

            return mailboxIDs.contains(binding.mailboxID.rawValue)

        case .unifiedLabel(let labelID):
            guard
                let binding = mailboxes.first(where: {
                    $0.accountKey == accountKey && $0.labelID == labelID
                })
            else { return nil }

            return mailboxIDs.contains(binding.mailboxID.rawValue)

        case .category(let wanted):
            guard
                let inbox = mailboxes.first(where: {
                    $0.accountKey == accountKey && $0.role == .inbox
                })
            else { return nil }

            // Both halves, and the inbox half first. Category membership hangs
            // off the inbox binding: a conversation archived in the browser
            // keeps its category, so testing the category alone would leave the
            // row on the Promotions list after it had left the Inbox.
            return mailboxIDs.contains(inbox.mailboxID.rawValue) && category == wanted

        case .mailbox(let feedAccountKey, let mailboxID):
            guard feedAccountKey == accountKey else { return nil }

            return mailboxIDs.contains(mailboxID.rawValue)
        }
    }

    /// Whether a row this old may be spliced into a list.
    ///
    /// A conversation from 2019 dragged back to the top of `Email/changes` by a
    /// read receipt must not be inserted under last week's mail: the list has
    /// never paged that far, so the row would sit above hundreds of messages
    /// newer than it with nothing between them. Only rows newer than the
    /// deepest the list has actually paged, or any row at all once the list has
    /// reached its end, are in the window.
    public static func isWithinWindow(_ sortDate: Date, cursor: FeedCursorSnapshot) -> Bool {
        if cursor.isExhausted { return true }

        guard let deepest = cursor.lastSortDate else {
            // Nothing paged yet. Splicing into a list that has never been
            // opened would show a single row and imply that is all there is.
            return false
        }

        return sortDate >= deepest
    }

    /// What one conversation's new mailbox set means for the lists this account
    /// has paged.
    ///
    /// `feeds` is every list this account holds a cursor for, with that cursor.
    ///
    /// `pendingTargets` names the conversations the offline queue has an
    /// opinion about, as ``ActionTarget/id``. A thread in there is skipped
    /// entirely: the server has not been told the user archived it, so it still
    /// says the conversation is in the inbox, and projecting that answer would
    /// put the row back on screen and make the gesture look ignored.
    public static func changes(
        threadID: String,
        accountKey: String,
        mailboxIDs: Set<String>,
        sortDate: Date,
        newestEmailID: String,
        feeds: [(feed: FeedID, cursor: FeedCursorSnapshot)],
        mailboxes: [MailboxSnapshot],
        pendingTargets: Set<String>,
        category: MessageCategory? = nil
    ) -> [FeedProjectionChange] {
        guard pendingTargets.contains("\(accountKey)#\(threadID)") == false else { return [] }

        var changes: [FeedProjectionChange] = []

        for entry in feeds {
            guard
                let belongs = belongs(
                    in: entry.feed, mailboxIDs: mailboxIDs, accountKey: accountKey,
                    mailboxes: mailboxes, category: category)
            else { continue }

            if belongs {
                guard isWithinWindow(sortDate, cursor: entry.cursor) else { continue }

                changes.append(
                    FeedProjectionChange(
                        feedID: entry.feed.rawValue,
                        accountKey: accountKey,
                        threadID: threadID,
                        kind: .insert(sortDate: sortDate, emailID: newestEmailID)
                    ))
            } else {
                // Symmetric by construction, and the half that matters most:
                // archiving in the browser is what removes the row here.
                changes.append(
                    FeedProjectionChange(
                        feedID: entry.feed.rawValue,
                        accountKey: accountKey,
                        threadID: threadID,
                        kind: .remove
                    ))
            }
        }

        return changes
    }
}
