import Foundation

/// One message that has arrived and might be worth saying something about.
///
/// A value type rather than a `MessageSnapshot` because the notification layer
/// needs two things the reader does not — the account's display name, so a
/// banner from a second mailbox says which one, and the raw mailbox bindings,
/// so the scope rules can be applied without a second trip to the store.
public struct NewMailMessage: Hashable, Sendable, Identifiable {
    public var accountKey: String
    /// What the banner calls the mailbox this arrived in. Resolved here rather
    /// than at post time because ``AccountSnapshot/displayName`` is the only
    /// thing that guarantees it is not blank, and a banner grouped under an
    /// empty name reads as a rendering bug.
    public var accountName: String
    public var threadID: String
    public var emailID: String
    public var senderName: String?
    public var senderAddress: String?
    public var subject: String?
    public var preview: String
    public var receivedAt: Date
    /// The message's mailbox bindings, for ``NotifyScopes``. Carried rather
    /// than resolved in the query so the veto rules stay pure and testable.
    public var mailboxIDs: Set<String>

    /// The dedupe key, and the same shape ``StoreKey/object(accountKey:id:)``
    /// uses. Two accounts on one server hand out overlapping message ids, so
    /// an unqualified id would silence one account's mail because another
    /// account had already announced that number.
    public var id: String { "\(accountKey)#\(emailID)" }

    public init(
        accountKey: String,
        accountName: String,
        threadID: String,
        emailID: String,
        senderName: String? = nil,
        senderAddress: String? = nil,
        subject: String? = nil,
        preview: String = "",
        receivedAt: Date,
        mailboxIDs: Set<String> = []
    ) {
        self.accountKey = accountKey
        self.accountName = accountName
        self.threadID = threadID
        self.emailID = emailID
        self.senderName = senderName
        self.senderAddress = senderAddress
        self.subject = subject
        self.preview = preview
        self.receivedAt = receivedAt
        self.mailboxIDs = mailboxIDs
    }

    /// Never empty. A sender with neither a name nor an address is rare and
    /// real — a bounce from a misconfigured relay — and a banner whose title
    /// is blank looks like the app failed rather than like the mail is odd.
    public var senderDisplayName: String {
        if let senderName, senderName.isEmpty == false { return senderName }
        if let senderAddress, senderAddress.isEmpty == false { return senderAddress }

        return NotificationText.unknownSender
    }

    public var subjectDisplayText: String {
        guard let subject, subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else { return NotificationText.noSubject }

        return subject
    }
}

/// One conversation's worth of new mail — the unit a banner is posted for.
///
/// **One request per conversation, never per message.** A thread that gets
/// five replies while the phone is in a pocket is one thing that happened, and
/// five stacked banners for it buries whatever else arrived. iOS then groups
/// these by `threadIdentifier` on its own, which is why there is no
/// hand-built summary here.
public struct ConversationAnnouncement: Hashable, Sendable, Identifiable {
    public var accountKey: String
    public var accountName: String
    public var threadID: String
    /// Oldest first, so ``latest`` is the last one and the count reads the way
    /// a conversation does.
    public var messages: [NewMailMessage]

    /// The notification request identifier. Reusing it is what makes a reply
    /// in an already-announced thread **replace** the banner rather than
    /// stack a second one beside it.
    public var id: String { "\(accountKey)#\(threadID)" }

    public var latest: NewMailMessage {
        // `messages` is never empty by construction — ``group(_:)`` only ever
        // creates one of these from at least one message — but a crash in a
        // background refresh nobody is watching is the worst place to be right
        // about that, so the fallback is a real value.
        messages.last
            ?? NewMailMessage(
                accountKey: accountKey,
                accountName: accountName,
                threadID: threadID,
                emailID: "",
                receivedAt: .distantPast)
    }

    public var messageCount: Int { messages.count }

    public init(
        accountKey: String,
        accountName: String,
        threadID: String,
        messages: [NewMailMessage]
    ) {
        self.accountKey = accountKey
        self.accountName = accountName
        self.threadID = threadID
        self.messages = messages
    }
}

/// Deciding what actually gets said, given messages, mailboxes and the
/// preference.
///
/// Pure and free of `UserNotifications`, so the rules can be tested on the
/// host without a simulator — which is the difference between this policy
/// being covered and being hoped about.
public enum NewMailAnnouncement {
    /// The messages this policy permits, in the order given.
    public static func permitted(
        _ messages: [NewMailMessage],
        mailboxes: [MailboxSnapshot],
        policy: NotificationPolicy
    ) -> [NewMailMessage] {
        // Grouped per account first: mailbox ids are only meaningful within
        // their own account, and resolving a message's scopes against another
        // account's mailboxes would match on an id collision and announce mail
        // from a label the user muted.
        let byAccount = Dictionary(grouping: mailboxes, by: \.accountKey)

        return messages.filter { message in
            let scopes = NotifyScopes.scopes(
                forMailboxIDs: message.mailboxIDs,
                in: byAccount[message.accountKey] ?? [])

            return policy.allows(accountKey: message.accountKey, scopes: scopes)
        }
    }

    /// Collapses messages into one announcement per conversation.
    ///
    /// - Parameters:
    ///   - messages: Everything worth announcing, in any order.
    ///   - limit: A ceiling on conversations, newest first. A phone left in a
    ///     drawer over a weekend can come back to three hundred threads, and
    ///     posting all of them turns Notification Centre into something nobody
    ///     reads rather than something anybody scrolls.
    /// - Returns: One announcement per conversation, oldest first, so the
    ///   newest banner is posted last and lands on top.
    public static func group(
        _ messages: [NewMailMessage],
        limit: Int = 12
    ) -> [ConversationAnnouncement] {
        var order: [String] = []
        var grouped: [String: [NewMailMessage]] = [:]

        for message in messages.sorted(by: { $0.receivedAt < $1.receivedAt }) {
            let key = "\(message.accountKey)#\(message.threadID)"

            if grouped[key] == nil {
                grouped[key] = []
                order.append(key)
            }

            grouped[key]?.append(message)
        }

        let announcements =
            order
            .compactMap { key -> ConversationAnnouncement? in
                guard let group = grouped[key], let first = group.first else { return nil }

                return ConversationAnnouncement(
                    accountKey: first.accountKey,
                    accountName: first.accountName,
                    threadID: first.threadID,
                    messages: group)
            }
            // Newest conversation last, so trimming from the front keeps the
            // mail that just arrived rather than the mail from Friday.
            .sorted { $0.latest.receivedAt < $1.latest.receivedAt }

        return announcements.suffix(limit).map { $0 }
    }
}
