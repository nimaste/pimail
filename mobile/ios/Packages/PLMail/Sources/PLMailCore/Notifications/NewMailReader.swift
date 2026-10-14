import Foundation
import SwiftData

/// The store, read for the one question the notification layer asks: *what has
/// arrived that this device has not spoken about?*
///
/// **A second `@ModelActor`, and read-only.** `SyncStore` remains the only
/// writer — nothing here calls `modelContext.save()`. It is separate because
/// `Store/SyncStore.swift` belongs to another feature and this query belongs
/// to this one; a `@ModelActor` gets its own background context from the same
/// container, so the two are as isolated as any two callers of the store are.
///
/// Reading on its own context also keeps the query off the main actor. A
/// background refresh that fetched a hundred rows on the main context would
/// stall whatever `@Query` the list is running at the same moment.
@ModelActor
public actor NewMailReader {
    /// How far back a pass will look.
    ///
    /// A day, because the honest question is "what arrived while I wasn't
    /// looking", and mail older than that has been on the list through several
    /// foreground sessions already. It is a second brake behind
    /// ``NotifiedMessageStore``: if the dedupe record is ever lost, this caps
    /// the damage at one day of banners rather than the whole mailbox.
    public static let lookback: TimeInterval = 24 * 60 * 60

    /// A ceiling on rows read per account per pass, before grouping.
    ///
    /// The grouping limit is the one the user feels; this one protects the
    /// background refresh's few seconds of runtime from an account that
    /// received two thousand messages overnight.
    public static let candidateLimit = 200

    /// Unread mail this device may not have announced, newest first.
    ///
    /// Filters that must happen in the query rather than afterwards:
    ///
    /// - **`isSeen == false`.** Mail already read in the web UI is not news,
    ///   and announcing it is the complaint that reads as "the app doesn't
    ///   know what I've read".
    /// - **`isDraft == false`.** A draft the user is writing on another device
    ///   arrives through the same delta pull and is not incoming mail.
    ///
    /// - Parameters:
    ///   - accountKey: One account. Called per account so a failure on one
    ///     leaves the others announceable.
    ///   - accountName: What the banner should call it. Passed in because
    ///     ``AccountSnapshot/displayName`` is the only thing that guarantees a
    ///     non-blank name, and it is already resolved by the time this runs.
    ///   - since: The oldest `receivedAt` worth considering.
    ///   - limit: How many rows to read before the cut on `since` is applied.
    /// - Returns: Announceable candidates, newest first. Scope and dedupe are
    ///   applied by the caller, so this is a superset of what will be said.
    /// - Throws: Whatever SwiftData throws when the store cannot be read. A
    ///   pass that cannot read one account must not stop the others, so the
    ///   caller catches per account rather than around the loop.
    public func candidates(
        accountKey: String,
        accountName: String,
        since: Date,
        limit: Int = candidateLimit
    ) throws -> [NewMailMessage] {
        // `since` is deliberately **not** in the predicate. A fourth clause —
        // and an optional `Date` comparison at that — pushes `#Predicate` past
        // the point where the type checker gives up, and the failure is a
        // build error with no useful location. Sorted newest first and
        // limited, the cut costs one comparison per row in Swift and reads the
        // same number of rows either way.
        var descriptor = FetchDescriptor<StoredEmail>(
            predicate: #Predicate { email in
                email.accountKey == accountKey
                    && email.isSeen == false
                    && email.isDraft == false
            },
            sortBy: [SortDescriptor(\.receivedAt, order: .reverse)])

        descriptor.fetchLimit = limit

        return try modelContext.fetch(descriptor).compactMap { email in
            guard let receivedAt = email.receivedAt, receivedAt > since else { return nil }

            // A message with no thread cannot be announced: the request
            // identifier *is* the thread, and one keyed on an empty string
            // would have every such message replace the previous one.
            guard let threadID = email.threadID, threadID.isEmpty == false else { return nil }

            return NewMailMessage(
                accountKey: accountKey,
                accountName: accountName,
                threadID: threadID,
                emailID: email.emailID,
                senderName: email.fromName,
                senderAddress: email.fromAddress,
                subject: email.subject,
                preview: email.preview,
                receivedAt: receivedAt,
                mailboxIDs: Set(email.mailboxIDs))
        }
    }

    /// Conversation identifiers that still hold unread mail, for one account.
    ///
    /// The input to withdrawing a banner for mail read somewhere else. Android
    /// has no equivalent and leaves the stale row on the lock screen until the
    /// user swipes it; on iOS the delivered notification is addressable by
    /// identifier, so the limitation is not worth copying.
    public func unreadConversationIdentifiers(accountKey: String) throws -> Set<String> {
        let descriptor = FetchDescriptor<StoredThread>(
            predicate: #Predicate { thread in
                thread.accountKey == accountKey && thread.isUnread
            })

        return Set(try modelContext.fetch(descriptor).map { "\(accountKey)#\($0.threadID)" })
    }
}
