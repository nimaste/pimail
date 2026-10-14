import JMAPKit
import OSLog
import PLMailCore
import UserNotifications

/// What happens when someone presses Archive, Mark as read or Reply on a
/// banner.
///
/// Two rules, both taken from what the Android client learned the hard way:
///
/// - **None of these opens the app.** The actions are registered without
///   `.foreground`, and nothing here presents a view. Filing one message
///   should leave the phone in the pocket.
/// - **The banner goes first, unconditionally.** A home server on a domestic
///   uplink can take seconds to answer, and an action that waits for it looks
///   broken and invites a second press — which on Archive means archiving
///   twice and on Reply means sending twice. The row disappears immediately
///   and the server work happens behind it; every action here is already
///   optimistic and already queued locally, so there is nothing to roll back
///   if the server is unreachable.
extension AppModel {
    private static let logger = Logger(subsystem: "de.plmail", category: "notify")

    /// Handles one notification response.
    ///
    /// May run before any UI has existed: an action taken from the lock screen
    /// after a reboot launches the app straight into this. ``load()`` is
    /// called for the same reason ``refreshInBackground()`` calls it — to
    /// rebuild just enough to do the work.
    func handle(_ response: UNNotificationResponse) async {
        if sync == nil { load() }

        let request = response.notification.request
        let info = request.content.userInfo

        guard
            let accountKey = info[MailNotifications.UserInfo.accountKey] as? String,
            let threadID = info[MailNotifications.UserInfo.threadID] as? String
        else { return }

        // Before anything that can fail or wait.
        MailNotifications.withdraw(identifiers: [request.identifier])

        switch response.actionIdentifier {
        case MailNotifications.Identifier.archive:
            await archiveFromNotification(accountKey: accountKey, threadID: threadID)

        case MailNotifications.Identifier.markRead:
            await markReadFromNotification(accountKey: accountKey, threadID: threadID)

        case MailNotifications.Identifier.reply, MailNotifications.Identifier.retryReply:
            guard let text = (response as? UNTextInputNotificationResponse)?.userText
            else { return }

            await reply(
                text: text,
                accountKey: accountKey,
                threadID: threadID,
                emailID: info[MailNotifications.UserInfo.emailID] as? String)

        default:
            // The default action is a tap, which opens the app. Both ids are
            // in hand here and used to be dropped, so the tap opened the
            // mailbox and left the person to find the message the banner had
            // just shown them. `IntentRouter` is the one indirection that
            // reaches the view tree from outside it — the same route Shortcuts
            // and Spotlight take.
            IntentRouter.shared.request(.thread(accountKey: accountKey, threadID: threadID))
        }

        await refreshBadge()
    }

    // MARK: - Actions

    private func archiveFromNotification(accountKey: String, threadID: String) async {
        guard let target = await actionTarget(accountKey: accountKey, threadID: threadID),
            let actions = notificationActions
        else { return }

        await actions.archive(target)
    }

    private func markReadFromNotification(accountKey: String, threadID: String) async {
        guard let target = await actionTarget(accountKey: accountKey, threadID: threadID),
            let actions = notificationActions
        else { return }

        await actions.setSeen(true, target)
    }

    /// The thread, as an action needs it.
    ///
    /// Read from the cache rather than the server: the banner exists because a
    /// sync already wrote these rows, and asking the server again before
    /// archiving would put a round trip in front of an action whose whole
    /// point is that it is instant.
    private func actionTarget(accountKey: String, threadID: String) async -> ActionTarget? {
        guard let sync,
            let account = sync.accounts.first(where: { $0.accountKey == accountKey })
        else { return nil }

        let messages = (try? await sync.store.messages(threadID: threadID, accountKey: accountKey))

        guard let messages, messages.isEmpty == false else { return nil }

        return ActionTarget(
            threadID: threadID,
            accountKey: accountKey,
            accountID: account.accountID,
            emailIDs: messages.map { EmailID($0.emailID) })
    }

    // MARK: - Inline reply

    /// Queues a reply typed into the banner.
    ///
    /// Handed to the outbox rather than sent, so the words are on disk before
    /// anything is attempted. Everything after that — a server that refuses, a
    /// train tunnel, the app being killed — is the outbox's existing retry, not
    /// a new failure path invented for notifications.
    ///
    /// The one case that still loses text is the outbox refusing to write it,
    /// which means the disk is full. That gets its own banner, carrying the
    /// typed words, so a retry does not ask anyone to write them again.
    private func reply(
        text: String,
        accountKey: String,
        threadID: String,
        emailID: String?
    ) async {
        guard let sync, let outbox else {
            await failReply(
                text: text, accountKey: accountKey, threadID: threadID, emailID: emailID ?? "")
            return
        }

        let store = sync.store

        // The message the banner was about, or the newest in the thread if the
        // banner predates it. Replying to the newest message is what the
        // reader does, and it is what keeps the threading headers right.
        let original: MessageSnapshot? = await {
            if let emailID,
                let message = try? await store.message(
                    emailID: emailID, accountKey: accountKey)
            {
                return message
            }

            return (try? await store.messages(threadID: threadID, accountKey: accountKey))?.last
        }()

        guard let original,
            let account = sync.accounts.first(where: { $0.accountKey == accountKey }),
            let identity = (try? await store.identities(accountKey: accountKey))?.first,
            let pending = NotificationReply.pendingMessage(
                replyingTo: original,
                identity: identity,
                accountID: account.accountID,
                text: text)
        else {
            await failReply(
                text: text, accountKey: accountKey, threadID: threadID, emailID: emailID ?? "")
            return
        }

        do {
            _ = try await outbox.queue.enqueue(pending)
        } catch {
            Self.logger.error("Could not queue a reply: \(error, privacy: .public)")
            await failReply(
                text: text, accountKey: accountKey, threadID: threadID,
                emailID: original.emailID)

            return
        }

        await outbox.refreshCount()
        outbox.drain()
    }

    private func failReply(
        text: String,
        accountKey: String,
        threadID: String,
        emailID: String
    ) async {
        await MailNotifications.postReplyFailure(
            accountKey: accountKey, threadID: threadID, emailID: emailID, text: text)
    }
}
