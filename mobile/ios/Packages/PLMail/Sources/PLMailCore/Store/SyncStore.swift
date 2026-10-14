import Foundation
import JMAPKit
import SwiftData

/// The only thing that writes to the store.
///
/// A `@ModelActor`, so it owns a background context and the UI's `@Query` on
/// the main context stays responsive while a sync runs. SwiftData propagates
/// saves from here to the main context, `@Query` re-runs, and SwiftUI diffs.
///
/// Saves are batched per sync unit rather than per object: a page of fifty
/// emails is one save, not fifty.
@ModelActor
public actor SyncStore {
    // MARK: - Accounts

    /// Reconciles the account list with what the Session reports.
    ///
    /// Accounts the server no longer lists are removed along with everything
    /// they own — a disconnected mailbox should not leave a ghost in the
    /// sidebar.
    @discardableResult
    public func syncAccounts(session: Session, serverID: String) throws -> [AccountSnapshot] {
        let ordered = session.orderedAccounts
        var live: Set<String> = []

        for (index, entry) in ordered.enumerated() {
            let key = StoreKey.account(server: serverID, account: entry.id)
            live.insert(key)

            let account =
                try account(key) ?? insertAccount(key: key, serverID: serverID, id: entry.id)
            // Not assigned blindly: a JMAP account may carry no name at all,
            // and overwriting a good one with an empty string on every sync
            // would undo the backfill in `replaceIdentities` a moment later.
            if entry.account.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                account.name = entry.account.name
            }
            account.isPersonal = entry.account.isPersonal
            account.isReadOnly = entry.account.isReadOnly
            account.sortIndex = index
        }

        for stale in try allAccounts() where live.contains(stale.uid) == false {
            try deleteEverything(forAccountKey: stale.uid)
            modelContext.delete(stale)
        }

        try modelContext.save()

        return try allAccounts()
            .sorted { $0.sortIndex < $1.sortIndex }
            .map(snapshot(of:))
    }

    public func accounts() throws -> [AccountSnapshot] {
        try allAccounts()
            .sorted { $0.sortIndex < $1.sortIndex }
            .map(snapshot(of:))
    }

    public func recordSyncFailure(_ message: String?, accountKey: String) throws {
        guard let account = try account(accountKey) else { return }
        account.lastSyncError = message
        try modelContext.save()
    }

    public func recordSyncSuccess(accountKey: String) throws {
        guard let account = try account(accountKey) else { return }
        account.lastSyncedAt = .now
        account.lastSyncError = nil
        try modelContext.save()
    }

    // MARK: - Mailboxes

    @discardableResult
    public func replaceMailboxes(
        _ mailboxes: [Mailbox],
        accountKey: String,
        state: StateToken
    ) throws -> [MailboxSnapshot] {
        var live: Set<String> = []

        for mailbox in mailboxes {
            let uid = StoreKey.object(accountKey: accountKey, id: mailbox.id.rawValue)
            live.insert(uid)

            let stored =
                try existing(StoredMailbox.self, uid: uid)
                ?? {
                    let new = StoredMailbox(
                        uid: uid, accountKey: accountKey, mailboxID: mailbox.id.rawValue,
                        name: mailbox.name ?? "")
                    modelContext.insert(new)
                    return new
                }()

            stored.labelID = mailbox.labelID?.rawValue
            stored.name = mailbox.name ?? stored.name
            stored.parentID = mailbox.parentID?.rawValue
            stored.role = mailbox.role?.rawValue
            // Without this line every label reads back as "no colour chosen"
            // and falls into the hashed fallback tint, so a colour the user
            // picked on the web is stored on the wire, decoded, and silently
            // dropped one assignment short of the row.
            stored.color = mailbox.color?.rawValue
            stored.sortOrder = mailbox.sortOrder ?? 0
            stored.totalEmails = mailbox.totalEmails ?? 0
            stored.unreadEmails = mailbox.unreadEmails ?? 0
            stored.totalThreads = mailbox.totalThreads ?? 0
            stored.unreadThreads = mailbox.unreadThreads ?? 0
            stored.isSubscribed = mailbox.isSubscribed ?? true
            stored.mayRename = mailbox.myRights?.mayRename ?? false
            stored.mayDelete = mailbox.myRights?.mayDelete ?? false
        }

        for stale in try mailboxRows(accountKey: accountKey)
        where live.contains(stale.uid) == false {
            modelContext.delete(stale)
        }

        if let account = try account(accountKey) {
            account.mailboxState = state.rawValue
        }

        try modelContext.save()

        return try mailboxRows(accountKey: accountKey).map(snapshot(of:))
    }

    public func mailbox(role: MailboxRole, accountKey: String) throws -> MailboxID? {
        let wanted = role.rawValue

        return try mailboxRows(accountKey: accountKey)
            .first { $0.role == wanted }
            .map { MailboxID($0.mailboxID) }
    }

    /// This account's binding for a user-scoped label.
    ///
    /// The translation the `labelId` extension exists for: one label spans
    /// every account, but the id that may be sent to the server is the
    /// per-account binding. Nil when this account has no binding for it, which
    /// is normal rather than exceptional — a label the user only ever applied
    /// in one mailbox has no binding in the others.
    public func mailbox(labelID: LabelID, accountKey: String) throws -> MailboxID? {
        let wanted = labelID.rawValue

        return try mailboxRows(accountKey: accountKey)
            .first { $0.labelID == wanted }
            .map { MailboxID($0.mailboxID) }
    }

    /// The user-scoped label id behind a binding, if it has one.
    ///
    /// The translation the other way round, and it exists for the offline
    /// queue: a queued label change may only hold the user-scoped id, because a
    /// binding id is valid against one account, can be recreated with a
    /// different number when a label is deleted and remade, and would then
    /// apply the wrong label on a drain. Nil for a role mailbox, which has no
    /// `labelId` at all.
    public func labelID(mailboxID: String, accountKey: String) throws -> LabelID? {
        try mailboxRows(accountKey: accountKey)
            .first { $0.mailboxID == mailboxID }?
            .labelID
            .map { LabelID($0) }
    }

    public func mailboxes(accountKey: String) throws -> [MailboxSnapshot] {
        try mailboxRows(accountKey: accountKey).map(snapshot(of:))
    }

    // MARK: - Emails and threads

    /// Writes a page of emails and the threads they belong to.
    ///
    /// - Parameters:
    ///   - emails: The page's emails, in the order they should appear.
    ///   - threads: `Thread/get` results for the same page, which carry the
    ///     full email-id list per thread. Fetched in the same round trip via a
    ///     chained back-reference, so the message count on a row is correct
    ///     without an extra request.
    ///   - accountKey: Which account these belong to.
    ///   - emailState: The state token to resume `Email/changes` from, if the
    ///     caller has one.
    /// - Throws: Whatever the underlying `ModelContext` save throws.
    public func upsert(
        emails: [Email],
        threads: [MailThread],
        accountKey: String,
        emailState: StateToken?
    ) throws {
        var threadEmailIDs: [String: [String]] = [:]
        var snoozedUntil: [String: Date] = [:]
        var category: [String: MessageCategory] = [:]
        var isNew: [String: Bool] = [:]

        for thread in threads {
            threadEmailIDs[thread.id.rawValue] = thread.emailIDs.map(\.rawValue)
            snoozedUntil[thread.id.rawValue] = thread.snoozedUntil?.date
            category[thread.id.rawValue] = thread.category
            isNew[thread.id.rawValue] = thread.isNew
        }

        for email in emails {
            let stored = try upsertEmail(email, accountKey: accountKey)

            guard let threadID = stored.threadID else { continue }

            try updateThread(
                threadID,
                accountKey: accountKey,
                from: stored,
                emailIDs: threadEmailIDs[threadID],
                // Only when this batch actually carried the thread. A page
                // that fetched emails without their threads must not read a
                // missing key as "no longer snoozed" and clear the badge.
                snoozedUntil: threadEmailIDs[threadID] != nil
                    ? .some(snoozedUntil[threadID]) : nil,
                // Same discipline, and it matters more here: nil category is a
                // real value ("no tab"), so a page that fetched emails without
                // their threads must not be read as the classifier having
                // changed its mind and emptied every tab.
                category: threadEmailIDs[threadID] != nil ? .some(category[threadID]) : nil,
                isNew: isNew[threadID]
            )
        }

        if let emailState, let account = try account(accountKey) {
            account.emailState = emailState.rawValue
        }

        try modelContext.save()
    }

    @discardableResult
    private func upsertEmail(_ email: Email, accountKey: String) throws -> StoredEmail {
        let uid = StoreKey.object(accountKey: accountKey, id: email.id.rawValue)

        let stored =
            try existing(StoredEmail.self, uid: uid)
            ?? {
                let new = StoredEmail(uid: uid, accountKey: accountKey, emailID: email.id.rawValue)
                modelContext.insert(new)
                return new
            }()

        // Every property is applied only when the response carried it: a
        // narrowed `properties` request is the normal case, and overwriting a
        // cached subject with nil because this call didn't ask for it would
        // make the list flicker empty on every refresh.
        if let threadID = email.threadID { stored.threadID = threadID.rawValue }
        if let blobID = email.blobID { stored.blobID = blobID.rawValue }
        if let receivedAt = email.receivedAt { stored.receivedAt = receivedAt.date }
        if let sentAt = email.sentAt { stored.sentAt = sentAt.date }
        if let subject = email.subject { stored.subject = subject }
        if let messageID = email.messageID?.first { stored.messageID = messageID }
        if let references = email.references { stored.references = references }
        if let preview = email.preview { stored.preview = preview }
        if let size = email.size { stored.size = size }
        if let hasAttachment = email.hasAttachment { stored.hasAttachment = hasAttachment }

        if let from = email.from?.first {
            stored.fromName = from.name
            stored.fromAddress = from.email
        }

        if let to = email.to { stored.toJSON = try? JSONEncoder().encode(to) }
        if let cc = email.cc { stored.ccJSON = try? JSONEncoder().encode(cc) }
        if let bcc = email.bcc { stored.bccJSON = try? JSONEncoder().encode(bcc) }

        if let keywords = email.keywords {
            stored.isSeen = keywords.contains(.seen)
            stored.isFlagged = keywords.contains(.flagged)
            stored.isDraft = keywords.contains(.draft)
            stored.isAnswered = keywords.contains(.answered)
        }

        if let mailboxIDs = email.mailboxIDs {
            stored.mailboxIDs = mailboxIDs.elements.map(\.rawValue).sorted()
        }

        return stored
    }

    private func updateThread(
        _ threadID: String,
        accountKey: String,
        from email: StoredEmail,
        emailIDs: [String]?,
        /// Double optional on purpose: nil means "this batch said nothing
        /// about the snooze", `.some(nil)` means "the server says it is not
        /// snoozed". Collapsing the two would clear the badge on every page
        /// that fetched emails without their threads.
        snoozedUntil: Date??,
        /// Double optional for the same reason as the snooze, and a sharper
        /// one: nil is a *meaningful* category — "no tab" — so there is no
        /// sentinel value left to mean "this batch said nothing".
        category: MessageCategory?? = nil,
        /// Single optional: nil means the batch carried no thread for this
        /// conversation. Never written back to true from a page that did not
        /// mention it, because a locally-retired marker would otherwise
        /// reappear on the next page that happened to omit the thread.
        isNew: Bool? = nil
    ) throws {
        let uid = StoreKey.object(accountKey: accountKey, id: threadID)

        let thread =
            try existing(StoredThread.self, uid: uid)
            ?? {
                let new = StoredThread(uid: uid, accountKey: accountKey, threadID: threadID)
                modelContext.insert(new)
                return new
            }()

        if let emailIDs {
            thread.emailIDs = emailIDs
            thread.messageCount = emailIDs.count
        } else if thread.emailIDs.contains(email.emailID) == false {
            thread.emailIDs.append(email.emailID)
            thread.messageCount = thread.emailIDs.count
        }

        // Thread-level, so it is applied before the newest-message guard
        // below: a snooze belongs to the conversation, and an older message
        // arriving late must still not drop it.
        if let snoozedUntil {
            thread.snoozedUntil = snoozedUntil
        }

        // Also thread-level, and also before the newest-message guard: the
        // category is resolved most-recent-wins by the server, and the New
        // marker belongs to the conversation rather than to any message in it.
        if let category {
            thread.category = category?.rawValue
        }

        if let isNew {
            thread.isNew = isNew
        }

        // The row renders from the newest message, so older ones arriving
        // later must not overwrite it.
        let incoming = email.receivedAt ?? .distantPast

        guard incoming >= thread.latestReceivedAt else { return }

        thread.latestReceivedAt = incoming
        thread.subject = email.subject
        thread.snippet = email.preview
        thread.hasAttachment = email.hasAttachment
        thread.isFlagged = email.isFlagged
        thread.isUnread = email.isSeen == false

        // Participants should be everyone who has written, oldest first — the
        // web UI is deliberate about that, because using the newest sender
        // made every thread you had answered look like it came from you.
        // Until the reader fetches whole threads, this is the newest sender,
        // which is right for the single-message threads that dominate a list.
        thread.participantsSummary = email.fromName ?? email.fromAddress ?? ""
        thread.participantsAddress = email.fromAddress
        thread.isDraft = email.isDraft
        thread.newestEmailID = email.emailID
    }

    /// Writes the parts of an Email that only the reader needs.
    ///
    /// Kept separate from the list-row upsert so that syncing a list never
    /// faults a body into memory: a page of fifty messages with their HTML is
    /// megabytes, and none of it is on screen.
    public func storeReaderContent(_ emails: [Email], accountKey: String) throws {
        for email in emails {
            let uid = StoreKey.object(accountKey: accountKey, id: email.id.rawValue)

            guard let stored = try existing(StoredEmail.self, uid: uid) else { continue }

            if let text = email.textBodyValue ?? email.htmlBodyValue {
                let body = stored.body ?? StoredEmailBody(uid: uid)
                body.textBody = email.textBodyValue
                body.htmlBody = email.htmlBodyValue
                body.fetchedAt = .now
                stored.body = body
                // Not inserted separately: assigning through the relationship
                // is what makes the cascade delete rule apply.
                _ = text
            }

            if let attachments = email.attachments {
                for existing in stored.attachments {
                    modelContext.delete(existing)
                }

                stored.attachments = attachments.compactMap { part in
                    guard let blobID = part.blobID, let partID = part.partID else { return nil }

                    let attachment = StoredAttachment(
                        uid: "\(uid)/\(partID)",
                        accountKey: accountKey,
                        partID: partID,
                        blobID: blobID.rawValue
                    )
                    attachment.name = part.name
                    attachment.type = part.type ?? "application/octet-stream"
                    attachment.size = part.size ?? 0
                    attachment.cid = part.cid
                    attachment.isInline = part.isInline

                    return attachment
                }
            }
        }

        try modelContext.save()
    }

    /// Marks emails read or unread locally.
    ///
    /// Applied before the server is told, so the row updates the moment the
    /// thread opens; the write follows and reconciles.
    public func setSeen(_ isSeen: Bool, emailIDs: [String], accountKey: String) throws {
        var touchedThreads: Set<String> = []

        for emailID in emailIDs {
            let uid = StoreKey.object(accountKey: accountKey, id: emailID)

            guard let email = try existing(StoredEmail.self, uid: uid) else { continue }

            email.isSeen = isSeen

            if let threadID = email.threadID { touchedThreads.insert(threadID) }
        }

        for threadID in touchedThreads {
            try recomputeUnread(threadID: threadID, accountKey: accountKey)
        }

        try modelContext.save()
    }

    /// A thread is unread when any message in it is.
    private func recomputeUnread(threadID: String, accountKey: String) throws {
        let uid = StoreKey.object(accountKey: accountKey, id: threadID)

        guard let thread = try existing(StoredThread.self, uid: uid) else { return }

        let emails = try thread.emailIDs.compactMap { emailID in
            try existing(
                StoredEmail.self,
                uid: StoreKey.object(accountKey: accountKey, id: emailID))
        }

        // Only recomputed from messages actually cached: a thread whose older
        // messages have not been fetched should not flip to read because they
        // are absent.
        guard emails.isEmpty == false else { return }

        thread.isUnread = emails.contains { $0.isSeen == false }
    }

    /// Every message in a thread, oldest first, as values.
    /// Recomputes a thread's participant summary from every message of it the
    /// store actually holds.
    ///
    /// The list sync only ever sees the newest message per thread — that is
    /// what `collapseThreads` returns — so the row is initially summarised by
    /// its newest sender, which makes every conversation you have answered look
    /// like it came from you. The web UI shows participants oldest-first, and
    /// the reader is the first moment this client has the whole thread.
    ///
    /// So it corrects on read rather than guessing on write: open a
    /// conversation once and its row is right from then on. That is a
    /// deliberate trade against fetching every sender up front, which would
    /// cost an `Email/get` per thread on a list nobody may scroll.
    public func refreshParticipants(threadID: String, accountKey: String) throws {
        let uid = StoreKey.object(accountKey: accountKey, id: threadID)

        guard let thread = try existing(StoredThread.self, uid: uid) else { return }

        var names: [String] = []
        var seen: Set<String> = []

        for emailID in thread.emailIDs {
            let uid = StoreKey.object(accountKey: accountKey, id: emailID)

            guard let email = try existing(StoredEmail.self, uid: uid),
                let address = email.fromAddress
            else { continue }

            // Keyed on the address so one person who has changed how their
            // client spells their name is still one participant.
            guard seen.insert(address.lowercased()).inserted else { continue }

            names.append(email.fromName ?? address)
        }

        guard names.isEmpty == false else { return }

        thread.participantsSummary = names.joined(separator: ", ")

        try modelContext.save()
    }

    /// One message, for the composer continuing a draft.
    public func message(emailID: String, accountKey: String) throws -> MessageSnapshot? {
        let uid = StoreKey.object(accountKey: accountKey, id: emailID)

        return try existing(StoredEmail.self, uid: uid).map(snapshot(of:))
    }

    public func messages(threadID: String, accountKey: String) throws -> [MessageSnapshot] {
        let uid = StoreKey.object(accountKey: accountKey, id: threadID)

        guard let thread = try existing(StoredThread.self, uid: uid) else { return [] }

        let emails = try thread.emailIDs.compactMap { emailID in
            try existing(
                StoredEmail.self,
                uid: StoreKey.object(accountKey: accountKey, id: emailID))
        }

        return
            emails
            .sorted { ($0.receivedAt ?? .distantPast) < ($1.receivedAt ?? .distantPast) }
            .map(snapshot(of:))
    }

    private func snapshot(of email: StoredEmail) -> MessageSnapshot {
        let decoder = JSONDecoder()

        return MessageSnapshot(
            emailID: email.emailID,
            accountKey: email.accountKey,
            blobID: email.blobID,
            subject: email.subject,
            fromName: email.fromName,
            fromAddress: email.fromAddress,
            to: (email.toJSON.flatMap { try? decoder.decode([EmailAddress].self, from: $0) }) ?? [],
            cc: (email.ccJSON.flatMap { try? decoder.decode([EmailAddress].self, from: $0) }) ?? [],
            receivedAt: email.receivedAt,
            messageID: email.messageID,
            references: email.references,
            preview: email.preview,
            isSeen: email.isSeen,
            isFlagged: email.isFlagged,
            isDraft: email.isDraft,
            htmlBody: email.body?.htmlBody,
            textBody: email.body?.textBody,
            hasBody: email.body != nil,
            attachments: email.attachments
                .filter { $0.isInline == false }
                .map(snapshot(of:)),
            inlineParts: email.attachments
                .filter(\.isInline)
                .map(snapshot(of:))
        )
    }

    private func snapshot(of attachment: StoredAttachment) -> AttachmentSnapshot {
        AttachmentSnapshot(
            partID: attachment.partID,
            blobID: attachment.blobID,
            name: attachment.name,
            type: attachment.type,
            size: attachment.size,
            cid: attachment.cid,
            isInline: attachment.isInline
        )
    }

    // MARK: - Identities and contacts

    public func replaceIdentities(_ identities: [Identity], accountKey: String) throws {
        try modelContext.delete(
            model: StoredIdentity.self, where: #Predicate { $0.accountKey == accountKey })

        for identity in identities {
            guard let email = identity.email else { continue }

            let stored = StoredIdentity(
                uid: StoreKey.object(accountKey: accountKey, id: identity.id.rawValue),
                accountKey: accountKey,
                identityID: identity.id.rawValue,
                email: email
            )
            stored.name = identity.name
            stored.textSignature = identity.textSignature
            // Stored verbatim, empty string included: `Identity/get` reports
            // `""` for an address the user has deliberately given no signature,
            // and collapsing that to nil here would make the settings screen
            // offer to "inherit the account's" on an address that has already
            // said it does not.
            stored.htmlSignature = identity.htmlSignature
            modelContext.insert(stored)
        }

        // A nameless account used to render as "Mailbox 1119" on every row of
        // a two-account inbox — an internal id, in front of the user, as the
        // only thing distinguishing one account from another. Its own address
        // is the thing people actually recognise, and by this point we have it.
        if let account = try account(accountKey),
            account.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let email = identities.compactMap(\.email)
                .first(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty == false })
        {
            account.name = email
        }

        try modelContext.save()
    }

    public func identities(accountKey: String) throws -> [IdentitySnapshot] {
        try modelContext.fetch(
            FetchDescriptor<StoredIdentity>(
                predicate: #Predicate { $0.accountKey == accountKey })
        )
        .map {
            IdentitySnapshot(
                id: IdentityID(rawValue: $0.identityID), name: $0.name, email: $0.email,
                textSignature: $0.textSignature, htmlSignature: $0.htmlSignature)
        }
    }

    /// What this device actually holds for one account.
    ///
    /// `fetchCount` rather than fetching and counting: the accounts screen asks
    /// this for every connected mailbox at once, and materialising a hundred
    /// thousand `StoredEmail` objects to learn how many there are is the kind
    /// of thing that makes a settings screen hang on the machines this app is
    /// built for.
    ///
    /// The oldest row is a separate one-row descriptor with `fetchLimit = 1`
    /// for the same reason — sorted ascending by `receivedAt`, so the store
    /// walks the index rather than the table.
    public func cachedWindow(accountKey: String) throws -> CachedWindowSnapshot {
        let count = try modelContext.fetchCount(
            FetchDescriptor<StoredEmail>(predicate: #Predicate { $0.accountKey == accountKey }))

        guard count > 0 else { return CachedWindowSnapshot(messageCount: 0) }

        var oldest = FetchDescriptor<StoredEmail>(
            predicate: #Predicate { $0.accountKey == accountKey },
            sortBy: [SortDescriptor(\.receivedAt, order: .forward)])
        oldest.fetchLimit = 1

        return CachedWindowSnapshot(
            messageCount: count,
            oldestReceivedAt: try modelContext.fetch(oldest).first?.receivedAt)
    }

    /// Addresses this account has corresponded with.
    ///
    /// Harvested from mail already on the device rather than fetched: the
    /// server exposes no JMAP Contacts, and the people someone writes to are
    /// exactly the people already in their mail.
    public func knownAddresses(accountKey: String, limit: Int = 500) throws -> [EmailAddress] {
        let emails = try modelContext.fetch(
            FetchDescriptor<StoredEmail>(
                predicate: #Predicate { $0.accountKey == accountKey },
                sortBy: [SortDescriptor(\.receivedAt, order: .reverse)]
            )
        )
        .prefix(limit)

        var byAddress: [String: EmailAddress] = [:]
        let decoder = JSONDecoder()

        for email in emails {
            if let address = email.fromAddress {
                byAddress[address.lowercased()] =
                    EmailAddress(name: email.fromName, email: address)
            }

            for data in [email.toJSON, email.ccJSON] {
                guard let data,
                    let addresses = try? decoder.decode([EmailAddress].self, from: data)
                else { continue }

                for address in addresses {
                    byAddress[address.email.lowercased()] = address
                }
            }
        }

        return byAddress.values.sorted { $0.email < $1.email }
    }

    // MARK: - Optimistic edits

    /// Takes a thread out of every list it appears in.
    ///
    /// Used for archive and trash, which both mean "not here any more" from
    /// the list's point of view. The thread itself is kept: it still exists on
    /// the server, and an undo should not have to re-fetch what was never
    /// really gone.
    /// - Returns: The rows removed, so they can be put back if the server
    ///   refuses the change they were anticipating.
    @discardableResult
    public func removeFromFeeds(
        _ threadID: String, accountKey: String
    ) throws
        -> [RemovedFeedRow]
    {
        let entries = try feedEntries(threadID: threadID, accountKey: accountKey)

        let removed = entries.map {
            RemovedFeedRow(
                feedID: $0.feedID, sortDate: $0.sortDate,
                accountKey: $0.accountKey, threadID: $0.threadID, emailID: $0.emailID)
        }

        for entry in entries {
            modelContext.delete(entry)
        }

        try modelContext.save()

        return removed
    }

    /// Puts optimistically-removed rows back where they were.
    ///
    /// The alternative — re-paging the feed — would move the reader's place
    /// for a change that never happened.
    public func restoreFeedRows(_ rows: [RemovedFeedRow]) throws {
        for row in rows {
            let uid = "\(row.feedID)#\(row.accountKey)#\(row.threadID)"

            guard try existing(StoredFeedEntry.self, uid: uid) == nil else { continue }

            modelContext.insert(
                StoredFeedEntry(
                    uid: uid, feedID: row.feedID, sortDate: row.sortDate,
                    accountKey: row.accountKey, threadID: row.threadID, emailID: row.emailID))
        }

        try modelContext.save()
    }

    public func setFlagged(_ isFlagged: Bool, emailIDs: [String], accountKey: String) throws {
        var threads: Set<String> = []

        for emailID in emailIDs {
            let uid = StoreKey.object(accountKey: accountKey, id: emailID)

            guard let email = try existing(StoredEmail.self, uid: uid) else { continue }

            email.isFlagged = isFlagged

            if let threadID = email.threadID { threads.insert(threadID) }
        }

        // A thread shows as starred when any message in it is — the same rule
        // the list row renders from.
        for threadID in threads {
            let uid = StoreKey.object(accountKey: accountKey, id: threadID)

            guard let thread = try existing(StoredThread.self, uid: uid) else { continue }

            let emails = try thread.emailIDs.compactMap { emailID in
                try existing(
                    StoredEmail.self,
                    uid: StoreKey.object(accountKey: accountKey, id: emailID))
            }

            thread.isFlagged = emails.contains(where: \.isFlagged)
        }

        try modelContext.save()
    }

    /// Records a label having been applied to or taken off messages.
    ///
    /// Local only, and optimistic: the server is still the authority on which
    /// mailboxes a message ends up in, and a refusal re-fetches over this.
    public func setMailbox(
        _ isApplied: Bool, mailboxID: String, emailIDs: [String], accountKey: String
    ) throws {
        for emailID in emailIDs {
            let uid = StoreKey.object(accountKey: accountKey, id: emailID)

            guard let email = try existing(StoredEmail.self, uid: uid) else { continue }

            if isApplied {
                // A set is idempotent on the wire; it has to be here too, or a
                // second tap leaves the id in twice and the picker starts
                // showing a label it can no longer take off.
                if email.mailboxIDs.contains(mailboxID) == false {
                    email.mailboxIDs.append(mailboxID)
                }
            } else {
                email.mailboxIDs.removeAll { $0 == mailboxID }
            }
        }

        try modelContext.save()
    }

    /// One message's mailbox ids, in the order they are stored.
    ///
    /// Internal because nothing in the app wants the order or the duplicates —
    /// the UI asks about a whole thread and gets a set. It exists so a test can
    /// see growth that a set would hide.
    func storedMailboxIDs(emailID: String, accountKey: String) throws -> [String] {
        let uid = StoreKey.object(accountKey: accountKey, id: emailID)

        return try existing(StoredEmail.self, uid: uid)?.mailboxIDs ?? []
    }

    /// When a conversation is due back, or nil when it is not snoozed.
    public func snoozedUntil(threadID: String, accountKey: String) throws -> Date? {
        let uid = StoreKey.object(accountKey: accountKey, id: threadID)

        return try existing(StoredThread.self, uid: uid)?.snoozedUntil
    }

    /// Which mailboxes a thread's messages are in.
    ///
    /// The union, not the intersection: the picker shows a label as applied if
    /// any message in the conversation carries it, matching how the list row
    /// already treats starred and unread.
    public func mailboxIDs(threadID: String, accountKey: String) throws -> Set<String> {
        let uid = StoreKey.object(accountKey: accountKey, id: threadID)

        guard let thread = try existing(StoredThread.self, uid: uid) else { return [] }

        var ids: Set<String> = []

        for emailID in thread.emailIDs {
            let uid = StoreKey.object(accountKey: accountKey, id: emailID)

            guard let email = try existing(StoredEmail.self, uid: uid) else { continue }

            ids.formUnion(email.mailboxIDs)
        }

        return ids
    }

    // MARK: - Delta sync

    public func setEmailState(_ state: StateToken, accountKey: String) throws {
        guard let account = try account(accountKey) else { return }

        account.emailState = state.rawValue
        try modelContext.save()
    }

    /// Forgets where sync had reached, so the next pass pages from the top.
    ///
    /// Feed cursors go with it: a cursor that cannot be resumed leaves the
    /// ordering it produced unverifiable, and keeping half of it would show a
    /// list with an invisible hole in the middle.
    public func clearCursors(accountKey: String) throws {
        if let account = try account(accountKey) {
            account.emailState = nil
            account.threadState = nil
        }

        try modelContext.delete(
            model: StoredFeedCursor.self,
            where: #Predicate { $0.accountKey == accountKey })
        try modelContext.delete(
            model: StoredFeedEntry.self,
            where: #Predicate { $0.accountKey == accountKey })

        try modelContext.save()
    }

    /// Removes messages the server says are gone, and any list row pointing at
    /// them.
    ///
    /// Note "destroyed" over JMAP is a move to Trash rather than a deletion —
    /// the message still exists, in another mailbox — so the *thread* is only
    /// removed once nothing is left of it here.
    public func removeEmails(_ emailIDs: [String], accountKey: String) throws {
        var affectedThreads: Set<String> = []

        for emailID in emailIDs {
            let uid = StoreKey.object(accountKey: accountKey, id: emailID)

            guard let email = try existing(StoredEmail.self, uid: uid) else { continue }

            if let threadID = email.threadID { affectedThreads.insert(threadID) }

            modelContext.delete(email)
        }

        for threadID in affectedThreads {
            let uid = StoreKey.object(accountKey: accountKey, id: threadID)

            guard let thread = try existing(StoredThread.self, uid: uid) else { continue }

            thread.emailIDs.removeAll(where: emailIDs.contains)

            guard thread.emailIDs.isEmpty else {
                thread.messageCount = thread.emailIDs.count
                continue
            }

            for entry in try feedEntries(threadID: threadID, accountKey: accountKey) {
                modelContext.delete(entry)
            }

            modelContext.delete(thread)
        }

        try modelContext.save()
    }

    private func feedEntries(threadID: String, accountKey: String) throws -> [StoredFeedEntry] {
        try modelContext.fetch(
            FetchDescriptor<StoredFeedEntry>(
                predicate: #Predicate { $0.threadID == threadID && $0.accountKey == accountKey }
            )
        )
    }

    // MARK: - Feed

    /// Replaces one account's slice of a feed with a freshly-paged prefix.
    public func replaceFeedSlice(
        _ rows: [FeedRow],
        feedID: String,
        accountKey: String,
        cursor: FeedCursorSnapshot
    ) throws {
        for stale in try feedEntries(feedID: feedID, accountKey: accountKey) {
            modelContext.delete(stale)
        }

        try appendFeedRows(rows, feedID: feedID, accountKey: accountKey, cursor: cursor)
    }

    /// Adds a page to the end of a feed.
    public func appendFeedRows(
        _ rows: [FeedRow],
        feedID: String,
        accountKey: String,
        cursor: FeedCursorSnapshot
    ) throws {
        for row in rows {
            let uid = "\(feedID)#\(accountKey)#\(row.threadID)"

            // A thread can be pushed into a later page by new mail arriving,
            // so the same thread can be paged twice. Updating rather than
            // inserting is what keeps it from appearing twice in the list.
            if let existing = try existing(StoredFeedEntry.self, uid: uid) {
                existing.sortDate = row.sortDate
                existing.emailID = row.emailID
                continue
            }

            modelContext.insert(
                StoredFeedEntry(
                    uid: uid,
                    feedID: feedID,
                    sortDate: row.sortDate,
                    accountKey: accountKey,
                    threadID: row.threadID,
                    emailID: row.emailID
                )
            )
        }

        try store(cursor, feedID: feedID, accountKey: accountKey)
        try modelContext.save()
    }

    /// Splices a freshly-fetched head onto an existing feed.
    ///
    /// Rows at or newer than `from` are replaced; everything older is left
    /// alone. That is what makes a refresh cheap and what keeps scroll
    /// position: re-running the whole feed on every foreground is exactly the
    /// aggressive-polling behaviour a self-hosted server cannot afford.
    ///
    /// - Returns: Whether the fresh head overlapped what was already stored.
    ///   No overlap means the list has moved further than one page — more mail
    ///   arrived than a page holds — and the caller should rebuild rather than
    ///   splice, because the gap between the two is unknown.
    @discardableResult
    public func spliceFeedHead(
        _ rows: [FeedRow],
        feedID: String,
        accountKey: String,
        from boundary: Date
    ) throws -> Bool {
        let stored = try feedEntries(feedID: feedID, accountKey: accountKey)
        let existingThreadIDs = Set(stored.map(\.threadID))
        let incomingThreadIDs = Set(rows.map(\.threadID))

        let overlaps =
            stored.isEmpty || incomingThreadIDs.isEmpty
            || existingThreadIDs.isDisjoint(with: incomingThreadIDs) == false

        for stale in stored where stale.sortDate >= boundary {
            modelContext.delete(stale)
        }

        for row in rows {
            let uid = "\(feedID)#\(accountKey)#\(row.threadID)"

            if let entry = try existing(StoredFeedEntry.self, uid: uid) {
                entry.sortDate = row.sortDate
                entry.emailID = row.emailID
                continue
            }

            modelContext.insert(
                StoredFeedEntry(
                    uid: uid, feedID: feedID, sortDate: row.sortDate,
                    accountKey: accountKey, threadID: row.threadID, emailID: row.emailID
                )
            )
        }

        try modelContext.save()

        return overlaps
    }

    /// Drops one account's slice of a feed and its cursor, so the next page
    /// starts from the top.
    public func resetFeed(feedID: String, accountKey: String) throws {
        for entry in try feedEntries(feedID: feedID, accountKey: accountKey) {
            modelContext.delete(entry)
        }

        if let cursor = try existing(StoredFeedCursor.self, uid: "\(feedID)#\(accountKey)") {
            modelContext.delete(cursor)
        }

        try modelContext.save()
    }

    public func cursor(feedID: String, accountKey: String) throws -> FeedCursorSnapshot {
        let uid = "\(feedID)#\(accountKey)"

        guard let stored = try existing(StoredFeedCursor.self, uid: uid) else {
            return FeedCursorSnapshot()
        }

        return FeedCursorSnapshot(
            lastSortDate: stored.lastSortDate,
            boundaryIDs: Set(stored.boundaryIDs),
            isExhausted: stored.isExhausted
        )
    }

    private func store(
        _ cursor: FeedCursorSnapshot,
        feedID: String,
        accountKey: String
    ) throws {
        let uid = "\(feedID)#\(accountKey)"

        let stored =
            try existing(StoredFeedCursor.self, uid: uid)
            ?? {
                let new = StoredFeedCursor(uid: uid, feedID: feedID, accountKey: accountKey)
                modelContext.insert(new)
                return new
            }()

        stored.lastSortDate = cursor.lastSortDate
        stored.boundaryIDs = Array(cursor.boundaryIDs)
        stored.isExhausted = cursor.isExhausted
    }

    /// Every row of a feed, newest first, as values.
    ///
    /// Snapshots rather than models because `@Model` types are not `Sendable`
    /// and must not leave the actor that owns their context. Exists for tests
    /// and diagnostics: the app itself reads the feed through `@Query`.
    public func feedRows(feedID: String) throws -> [FeedEntrySnapshot] {
        try modelContext.fetch(
            FetchDescriptor<StoredFeedEntry>(
                predicate: #Predicate { $0.feedID == feedID },
                sortBy: [SortDescriptor(\.sortDate, order: .reverse)]
            )
        )
        .map {
            FeedEntrySnapshot(
                accountKey: $0.accountKey,
                threadID: $0.threadID,
                emailID: $0.emailID,
                sortDate: $0.sortDate
            )
        }
    }

    // MARK: - Feed projection

    /// Every list this account has actually paged, with how deep.
    ///
    /// A feed exists on disk only once something has paged it, and the only
    /// record of which those are is the cursor table. ``FeedProjection`` needs
    /// the whole set: correcting the list on screen and no other is what leaves
    /// a conversation archived in the browser sitting in every cached list the
    /// user has not looked at lately.
    public func pagedFeeds(accountKey: String) throws -> [PagedFeed] {
        try modelContext.fetch(
            FetchDescriptor<StoredFeedCursor>(
                predicate: #Predicate { $0.accountKey == accountKey }
            )
        )
        .map {
            PagedFeed(
                feedID: $0.feedID,
                cursor: FeedCursorSnapshot(
                    lastSortDate: $0.lastSortDate,
                    boundaryIDs: Set($0.boundaryIDs),
                    isExhausted: $0.isExhausted
                )
            )
        }
    }

    /// What a projection needs to know about the conversations a sync touched.
    ///
    /// Read in one pass rather than per feed: the union of mailbox ids over a
    /// forty-message thread is the expensive part, and computing it once per
    /// list would multiply it by however many lists the account has paged.
    public func threadProjections(
        threadIDs: [String], accountKey: String
    ) throws -> [ThreadProjection] {
        var projections: [ThreadProjection] = []

        for threadID in threadIDs {
            let uid = StoreKey.object(accountKey: accountKey, id: threadID)

            guard let thread = try existing(StoredThread.self, uid: uid) else { continue }

            var mailboxIDs: Set<String> = []

            for emailID in thread.emailIDs {
                let emailUID = StoreKey.object(accountKey: accountKey, id: emailID)

                guard let email = try existing(StoredEmail.self, uid: emailUID) else { continue }

                mailboxIDs.formUnion(email.mailboxIDs)
            }

            projections.append(
                ThreadProjection(
                    threadID: threadID,
                    mailboxIDs: mailboxIDs,
                    sortDate: thread.latestReceivedAt,
                    newestEmailID: thread.newestEmailID ?? thread.emailIDs.last ?? threadID,
                    category: MessageCategory(wire: thread.category)
                ))
        }

        return projections
    }

    // MARK: - The New marker

    /// Records locally that these conversations have been drawn.
    ///
    /// Called only after the server has accepted the retirement, so a report
    /// that never reached the server leaves the column alone and the row is
    /// badged again next time it is drawn. Losing a marker the server still
    /// holds would be the worse failure of the two: the badge would be gone
    /// here and still up in the browser, with nothing left to retire it.
    ///
    /// One save for the batch. This runs behind a scrolling list, and a save
    /// per row is what turns a fling into a write per frame.
    public func clearNewMarkers(threadIDs: [String], accountKey: String) throws {
        guard threadIDs.isEmpty == false else { return }

        var changed = false

        for threadID in threadIDs {
            let uid = StoreKey.object(accountKey: accountKey, id: threadID)

            guard let thread = try existing(StoredThread.self, uid: uid), thread.isNew else {
                continue
            }

            thread.isNew = false
            changed = true
        }

        if changed { try modelContext.save() }
    }

    /// Which of these conversations still carry the New marker.
    ///
    /// A value out of the actor rather than a `@Model`, because `@Model`
    /// objects must never cross an actor boundary — the rule the whole snapshot
    /// layer exists to keep. Ids rather than a dictionary: the question is
    /// membership, and an absent id means "not new" whether the conversation is
    /// unmarked or not cached at all.
    public func newMarkers(threadIDs: [String], accountKey: String) throws -> Set<String> {
        var marked: Set<String> = []

        for threadID in threadIDs {
            let uid = StoreKey.object(accountKey: accountKey, id: threadID)

            if try existing(StoredThread.self, uid: uid)?.isNew == true {
                marked.insert(threadID)
            }
        }

        return marked
    }

    // MARK: - Categories

    /// Whether this server classifies mail at all.
    ///
    /// **Asked once, not per row.** A plMail instance whose classifier has
    /// never run answers every category query with nothing, and five permanently
    /// empty tabs above a working inbox is worse than no tabs: it reads as mail
    /// having gone missing. Any single conversation with a category is enough
    /// evidence, so this stops at the first hit rather than counting.
    ///
    /// Deliberately not "does this feed have categories": the control is drawn
    /// from the whole cache, so it does not appear and disappear as the user
    /// pages through mail that predates the classifier.
    public func hasCategorisedThreads() throws -> Bool {
        var descriptor = FetchDescriptor<StoredThread>(
            predicate: #Predicate { $0.category != nil })
        descriptor.fetchLimit = 1

        return try modelContext.fetchCount(descriptor) > 0
    }

    /// How many unread conversations this device holds under each category.
    ///
    /// **What this device holds**, and the tab says so by being a count rather
    /// than a claim about the server. There is no server-side figure to ask
    /// for: `Mailbox/get` counts a mailbox, and a category is not one — the
    /// classifier writes it onto the conversation. So the number is exactly
    /// what the list beneath the strip would show if you tapped the tab, which
    /// is the one definition that can never disagree with what is on screen.
    ///
    /// A `fetchCount` per category — four small indexed counts — rather than
    /// fetching the rows and grouping them in Swift. This runs whenever the
    /// feed changes, and on a sixty-thousand-message mailbox the difference
    /// between counting and materialising is the difference between a query
    /// and a stall.
    public func unreadCountsByCategory() throws -> [MessageCategory: Int] {
        var counts: [MessageCategory: Int] = [:]

        for category in MessageCategory.allCases {
            let raw = category.rawValue
            let descriptor = FetchDescriptor<StoredThread>(
                predicate: #Predicate { $0.isUnread && $0.category == raw })
            let count = try modelContext.fetchCount(descriptor)

            if count > 0 { counts[category] = count }
        }

        return counts
    }

    /// Applies a whole batch of projection decisions in one transaction.
    ///
    /// One save for the batch, not one per row: this runs on the sync path
    /// after every hydrate, and a save per changed conversation would make a
    /// delta pull of two hundred messages two hundred writes on a device that
    /// is often on battery.
    public func applyProjection(_ changes: [FeedProjectionChange]) throws {
        guard changes.isEmpty == false else { return }

        for change in changes {
            let uid = "\(change.feedID)#\(change.accountKey)#\(change.threadID)"

            switch change.kind {
            case .remove:
                guard let entry = try existing(StoredFeedEntry.self, uid: uid) else { continue }

                modelContext.delete(entry)

            case .insert(let sortDate, let emailID):
                if let entry = try existing(StoredFeedEntry.self, uid: uid) {
                    // Updated rather than left alone: new mail in a thread
                    // moves it up the list, and a row that keeps its old sort
                    // date sits below messages older than its newest reply.
                    entry.sortDate = sortDate
                    entry.emailID = emailID
                    continue
                }

                modelContext.insert(
                    StoredFeedEntry(
                        uid: uid,
                        feedID: change.feedID,
                        sortDate: sortDate,
                        accountKey: change.accountKey,
                        threadID: change.threadID,
                        emailID: emailID
                    ))
            }
        }

        try modelContext.save()
    }

    // MARK: - Bodies

    /// Messages this device holds no body for, newest first.
    ///
    /// Newest first because that is what a person opens on a train, and limited
    /// because the prefetcher's whole point is a budget: bodies are large and
    /// the server is often a Raspberry Pi.
    ///
    /// Note this is "no body row at all", not "no body text" — see
    /// ``recordMissingBody(emailIDs:accountKey:)`` for why the difference
    /// matters.
    /// Walked in batches rather than filtered in a `#Predicate`: SwiftData
    /// cannot compile a comparison against a to-one relationship — `body ==
    /// nil` fails to type-check inside the macro — and fetching an account's
    /// whole message table to filter it in memory is the thing this query is
    /// supposed to avoid.
    /// Which of `emailIDs` this device holds no body for.
    ///
    /// The screen's question, where ``messagesWithoutBody(accountKey:limit:)``
    /// answers the mailbox's. Bounded by what was asked about rather than by a
    /// budget, because the caller is a list of rows somebody is looking at and
    /// there are only ever a screenful.
    public func emailsWithoutBody(among emailIDs: [String], accountKey: String) throws -> [String] {
        guard emailIDs.isEmpty == false else { return [] }

        let uids = Set(emailIDs.map { StoreKey.object(accountKey: accountKey, id: $0) })
        let descriptor = FetchDescriptor<StoredEmail>(
            predicate: #Predicate { uids.contains($0.uid) })

        // `body == nil` cannot be written inside the macro — SwiftData will not
        // compile a comparison against a to-one relationship — so the filter
        // happens here. Harmless at this size: the fetch is already bounded by
        // the ids handed in.
        return try modelContext.fetch(descriptor)
            .filter { $0.body == nil }
            .map(\.emailID)
    }

    public func messagesWithoutBody(accountKey: String, limit: Int) throws -> [String] {
        guard limit > 0 else { return [] }

        var found: [String] = []

        let descriptor = FetchDescriptor<StoredEmail>(
            predicate: #Predicate { $0.accountKey == accountKey },
            sortBy: [SortDescriptor(\.receivedAt, order: .reverse)]
        )

        // `enumerate` stops the moment the block throws, which is the only way
        // out of it — the budget has to be honoured or a mailbox with ten
        // thousand unfetched messages walks all of them on every run.
        struct Enough: Error {}

        do {
            try modelContext.enumerate(descriptor, batchSize: 100) { email in
                guard email.body == nil else { return }

                found.append(email.emailID)

                if found.count >= limit { throw Enough() }
            }
        } catch is Enough {
            // Expected: the budget was reached.
        }

        return found
    }

    /// Records that a message genuinely has no body to fetch.
    ///
    /// Without it the prefetcher re-considers the same messages on every run
    /// forever: a message with an empty body is indistinguishable from one that
    /// has never been fetched, so it consumes the budget every time and the
    /// mail behind it is never prefetched at all. An empty body row is the
    /// marker — the same answer Android writes, for the same reason.
    ///
    /// `fetchedAt` is set, so an eviction pass ages these out with everything
    /// else rather than leaving permanent tombstones.
    public func recordMissingBody(emailIDs: [String], accountKey: String) throws {
        for emailID in emailIDs {
            let uid = StoreKey.object(accountKey: accountKey, id: emailID)

            guard let email = try existing(StoredEmail.self, uid: uid), email.body == nil
            else { continue }

            let body = StoredEmailBody(uid: uid)
            body.fetchedAt = .now
            email.body = body
        }

        try modelContext.save()
    }

    // MARK: - Deletion

    public func deleteEverything() throws {
        for type in SchemaV1.models {
            try modelContext.delete(model: type)
        }
        try modelContext.save()
    }

    private func deleteEverything(forAccountKey accountKey: String) throws {
        try modelContext.delete(
            model: StoredMailbox.self,
            where: #Predicate { $0.accountKey == accountKey })
        try modelContext.delete(
            model: StoredThread.self, where: #Predicate { $0.accountKey == accountKey })
        try modelContext.delete(
            model: StoredEmail.self, where: #Predicate { $0.accountKey == accountKey })
        try modelContext.delete(
            model: StoredFeedEntry.self,
            where: #Predicate { $0.accountKey == accountKey })
        try modelContext.delete(
            model: StoredFeedCursor.self,
            where: #Predicate { $0.accountKey == accountKey })
        try modelContext.delete(
            model: StoredIdentity.self,
            where: #Predicate { $0.accountKey == accountKey })
    }

    // MARK: - Fetch helpers

    private func account(_ key: String) throws -> StoredAccount? {
        try existing(StoredAccount.self, uid: key)
    }

    private func insertAccount(
        key: String, serverID: String, id: AccountID
    ) -> StoredAccount {
        let account = StoredAccount(
            uid: key, serverID: serverID, accountID: id.rawValue, name: "")
        modelContext.insert(account)
        return account
    }

    private func allAccounts() throws -> [StoredAccount] {
        try modelContext.fetch(FetchDescriptor<StoredAccount>())
    }

    // Written out per type rather than generically: `#Predicate` is translated
    // into a query at compile time, so it cannot go through a protocol or a
    // dynamic key path. One-line functions are the honest way to say that.

    private func first<T: PersistentModel>(
        _ descriptor: FetchDescriptor<T>
    ) throws -> T? {
        var descriptor = descriptor
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func existing(_ type: StoredAccount.Type, uid: String) throws -> StoredAccount? {
        try first(FetchDescriptor<StoredAccount>(predicate: #Predicate { $0.uid == uid }))
    }

    private func existing(_ type: StoredMailbox.Type, uid: String) throws -> StoredMailbox? {
        try first(FetchDescriptor<StoredMailbox>(predicate: #Predicate { $0.uid == uid }))
    }

    private func existing(_ type: StoredEmail.Type, uid: String) throws -> StoredEmail? {
        try first(FetchDescriptor<StoredEmail>(predicate: #Predicate { $0.uid == uid }))
    }

    private func existing(_ type: StoredThread.Type, uid: String) throws -> StoredThread? {
        try first(FetchDescriptor<StoredThread>(predicate: #Predicate { $0.uid == uid }))
    }

    private func existing(_ type: StoredFeedEntry.Type, uid: String) throws -> StoredFeedEntry? {
        try first(FetchDescriptor<StoredFeedEntry>(predicate: #Predicate { $0.uid == uid }))
    }

    private func existing(_ type: StoredFeedCursor.Type, uid: String) throws -> StoredFeedCursor? {
        try first(FetchDescriptor<StoredFeedCursor>(predicate: #Predicate { $0.uid == uid }))
    }

    private func mailboxRows(accountKey: String) throws -> [StoredMailbox] {
        try modelContext.fetch(
            FetchDescriptor<StoredMailbox>(
                predicate: #Predicate { $0.accountKey == accountKey },
                sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)]
            )
        )
    }

    private func feedEntries(feedID: String, accountKey: String) throws -> [StoredFeedEntry] {
        try modelContext.fetch(
            FetchDescriptor<StoredFeedEntry>(
                predicate: #Predicate { $0.feedID == feedID && $0.accountKey == accountKey }
            )
        )
    }

    // MARK: - Snapshots

    private func snapshot(of account: StoredAccount) -> AccountSnapshot {
        AccountSnapshot(
            accountKey: account.uid,
            accountID: AccountID(account.accountID),
            name: account.name,
            emailState: account.emailState.map(StateToken.init(rawValue:)),
            threadState: account.threadState.map(StateToken.init(rawValue:)),
            mailboxState: account.mailboxState.map(StateToken.init(rawValue:)),
            isReadOnly: account.isReadOnly,
            lastSyncedAt: account.lastSyncedAt,
            lastSyncError: account.lastSyncError
        )
    }

    private func snapshot(of mailbox: StoredMailbox) -> MailboxSnapshot {
        MailboxSnapshot(
            accountKey: mailbox.accountKey,
            mailboxID: MailboxID(mailbox.mailboxID),
            labelID: mailbox.labelID.map { LabelID(rawValue: $0) },
            name: mailbox.name,
            role: mailbox.role.map(MailboxRole.init(rawValue:)),
            parentID: mailbox.parentID.map(MailboxID.init(rawValue:)),
            // `LabelColor(wire:)` rather than `LabelColor(rawValue:)` so a
            // token written by a newer server degrades to "no colour chosen"
            // instead of the snapshot failing to carry the label at all.
            color: LabelColor(wire: mailbox.color),
            unreadThreads: mailbox.unreadThreads,
            totalThreads: mailbox.totalThreads,
            isSubscribed: mailbox.isSubscribed,
            mayRename: mailbox.mayRename,
            mayDelete: mailbox.mayDelete
        )
    }
}

/// One row of a paged list, before it becomes a `StoredFeedEntry`.
public struct FeedRow: Hashable, Sendable {
    public var threadID: String
    public var emailID: String
    public var sortDate: Date

    public init(threadID: String, emailID: String, sortDate: Date) {
        self.threadID = threadID
        self.emailID = emailID
        self.sortDate = sortDate
    }
}

/// A list this account has paged, and how deep.
///
/// Carried as a value because `@Model` types are not `Sendable` and must never
/// leave the actor that owns their context — the rule the whole snapshot layer
/// exists to keep.
public struct PagedFeed: Hashable, Sendable {
    public var feedID: String
    public var cursor: FeedCursorSnapshot

    public init(feedID: String, cursor: FeedCursorSnapshot) {
        self.feedID = feedID
        self.cursor = cursor
    }
}

/// What a projection needs to know about one conversation.
///
/// Read once per sync batch rather than per list: the union of mailbox ids over
/// a long thread is the expensive part, and asking for it per feed would
/// multiply it by however many lists the account has paged.
public struct ThreadProjection: Hashable, Sendable {
    public var threadID: String
    /// The union across every message. A conversation is in a label if any of
    /// its messages is, matching how the list row already treats starred and
    /// unread.
    public var mailboxIDs: Set<String>
    public var sortDate: Date
    /// The row renders from the newest message, so a splice that named an
    /// older one would show the wrong sender under the right subject.
    public var newestEmailID: String
    /// Which tab this conversation is on, or nil for one the classifier never
    /// saw. Carried here so the projection can reconcile the category feeds
    /// without a second read per list — the whole reason this type exists.
    public var category: MessageCategory?

    public init(
        threadID: String,
        mailboxIDs: Set<String>,
        sortDate: Date,
        newestEmailID: String,
        category: MessageCategory? = nil
    ) {
        self.threadID = threadID
        self.mailboxIDs = mailboxIDs
        self.sortDate = sortDate
        self.newestEmailID = newestEmailID
        self.category = category
    }
}
