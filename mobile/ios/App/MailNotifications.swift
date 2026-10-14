import Intents
import OSLog
import PLMailCore
import UIKit
import UserNotifications

/// Everything this app says through `UserNotifications`.
///
/// **In `App/` rather than in the package, deliberately.**
/// `UNUserNotificationCenter.current()` traps in a process with no bundle
/// identifier, which is exactly what `swift test` runs on the host. Keeping
/// the framework out of `PLMailCore` is what lets the dedupe store and the
/// preference rules — the parts with real logic — be tested in milliseconds
/// without booting a simulator.
///
/// Nothing here builds a group summary. Android needs one because its shade
/// collapses a group without it; iOS groups by `threadIdentifier` on its own,
/// and a hand-posted summary would arrive as one extra banner nobody asked
/// for.
@MainActor
enum MailNotifications {
    private static let logger = Logger(subsystem: "de.plmail", category: "notify")

    /// Category and action identifiers.
    ///
    /// One category for every conversation rather than one per account.
    /// Android needs a channel per account because channels *are* its
    /// preference surface; iOS has one app-level permission, and per-account
    /// mute is an in-app preference here — see ``NotificationPolicy``. A
    /// category per account would multiply the registrations for no user-
    /// visible difference and would go stale the moment an account is removed.
    enum Identifier {
        static let conversation = "de.plmail.notification.conversation"
        /// A failed reply is its own category because it offers Try again and
        /// must **not** auto-dismiss — the typed words are in it.
        static let replyFailure = "de.plmail.notification.reply-failure"

        static let archive = "de.plmail.action.archive"
        static let markRead = "de.plmail.action.mark-read"
        static let reply = "de.plmail.action.reply"
        static let retryReply = "de.plmail.action.retry-reply"
    }

    /// Keys in `UNNotificationContent.userInfo`.
    ///
    /// A notification outlives the process that posted it: it can be actioned
    /// after a reboot, with no `AppModel` and no connection in memory. So
    /// everything needed to act on it travels inside it, rather than being
    /// looked up from state that may not exist.
    enum UserInfo {
        static let accountKey = "accountKey"
        static let threadID = "threadId"
        static let emailID = "emailId"
        /// The words someone typed, carried on a failure notification so a
        /// retry does not ask them to write it again.
        static let replyText = "replyText"
    }

    // MARK: - Registration

    /// Registers the categories once, at launch.
    ///
    /// Before any notification is posted, and not lazily beside the first
    /// post: a request whose `categoryIdentifier` names a category that is not
    /// registered yet arrives with **no actions at all**, silently. The banner
    /// looks right and Archive is simply missing.
    static func registerCategories() {
        let archive = UNNotificationAction(
            identifier: Identifier.archive,
            title: NotificationText.archive,
            // Not `.destructive`, and not `.foreground`. Archive is reversible
            // — the styling reserved for deletion would misdescribe it — and
            // an action that opens the app to file one message defeats the
            // point of putting it on the banner.
            options: [])

        let markRead = UNNotificationAction(
            identifier: Identifier.markRead,
            title: NotificationText.markAsRead,
            options: [])

        let reply = UNTextInputNotificationAction(
            identifier: Identifier.reply,
            title: NotificationText.reply,
            options: [],
            textInputButtonTitle: NotificationText.send,
            textInputPlaceholder: NotificationText.replyPlaceholder)

        let conversation = UNNotificationCategory(
            identifier: Identifier.conversation,
            actions: [reply, archive, markRead],
            intentIdentifiers: [],
            options: [])

        let retry = UNTextInputNotificationAction(
            identifier: Identifier.retryReply,
            title: NotificationText.tryAgain,
            options: [],
            textInputButtonTitle: NotificationText.send,
            textInputPlaceholder: NotificationText.replyPlaceholder)

        let failure = UNNotificationCategory(
            identifier: Identifier.replyFailure,
            actions: [retry],
            intentIdentifiers: [],
            options: [])

        UNUserNotificationCenter.current().setNotificationCategories([conversation, failure])
    }

    // MARK: - Permission

    /// Whether a banner posted now would be shown.
    ///
    /// Checked before every pass. `UNUserNotificationCenter` accepts a request
    /// and drops it when permission is absent, so without this a refusal is
    /// indistinguishable from mail that never arrived — and the dedupe store
    /// would meanwhile record every one of those messages as announced, so
    /// granting permission later would start from silence.
    static func isAuthorized() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()

        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        default: return false
        }
    }

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Spends the one-shot prompt.
    ///
    /// - Returns: Whether alerts may now be shown.
    static func requestAuthorization() async -> Bool {
        let granted =
            try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .badge, .sound])

        return granted ?? false
    }

    // MARK: - Posting

    /// Posts one banner per conversation.
    static func post(_ announcements: [ConversationAnnouncement]) async {
        guard announcements.isEmpty == false else { return }

        for announcement in announcements {
            let request = UNNotificationRequest(
                identifier: announcement.id,
                content: content(for: announcement),
                // Nil, not a one-second interval. A trigger would schedule the
                // banner rather than deliver it, and a scheduled notification
                // for mail that has already arrived is late by exactly as long
                // as the trigger.
                trigger: nil)

            do {
                try await UNUserNotificationCenter.current().add(request)
            } catch {
                logger.error("Could not post a banner: \(error, privacy: .public)")
            }
        }
    }

    private static func content(
        for announcement: ConversationAnnouncement
    )
        -> UNNotificationContent
    {
        let latest = announcement.latest
        let content = UNMutableNotificationContent()

        content.title = latest.senderDisplayName
        content.subtitle = latest.subjectDisplayText
        content.body =
            announcement.messageCount > 1
            ? NotificationText.moreMessages(announcement.messageCount)
            : latest.preview

        // Per account, so iOS stacks a busy mailbox under one heading and a
        // second mailbox under its own.
        //
        // `summaryArgument` deliberately unset: deprecated in iOS 15 and
        // documented as ignored, so setting it buys nothing and fails a build
        // that treats warnings as errors — which Release does. The system
        // composes the stack heading itself.
        content.threadIdentifier = announcement.accountKey
        content.categoryIdentifier = Identifier.conversation

        // `.active` rather than `.timeSensitive`: mail is not an alarm, and an
        // app that breaks through Focus for a newsletter is an app whose
        // notifications get switched off entirely.
        content.interruptionLevel = .active
        content.sound = .default

        content.userInfo = [
            UserInfo.accountKey: announcement.accountKey,
            UserInfo.threadID: announcement.threadID,
            UserInfo.emailID: latest.emailID,
        ]

        return communicationContent(content, from: latest, conversationID: announcement.id)
    }

    /// Turns the banner into a **communication** notification.
    ///
    /// This is the iOS answer to Android's `MessagingStyle`, and it is not
    /// cosmetic: it is what puts the sender's own name and contact photo on
    /// the banner, what lets someone allow mail from a particular person
    /// through a Focus, and what makes Announce Notifications read it as a
    /// message rather than as an app alert.
    ///
    /// Falls back to the plain content on failure. `updating(from:)` throws
    /// when the intent cannot be applied — an OS that has withdrawn the
    /// entitlement, a donation the system declined — and a banner without a
    /// contact photo is a far better outcome than no banner at all.
    private static func communicationContent(
        _ content: UNMutableNotificationContent,
        from message: NewMailMessage,
        conversationID: String
    ) -> UNNotificationContent {
        let handle = INPersonHandle(
            value: message.senderAddress, type: .emailAddress)

        let sender = INPerson(
            personHandle: handle,
            nameComponents: nil,
            displayName: message.senderDisplayName,
            image: nil,
            contactIdentifier: nil,
            customIdentifier: message.senderAddress)

        let intent = INSendMessageIntent(
            recipients: nil,
            outgoingMessageType: .outgoingMessageText,
            content: nil,
            speakableGroupName: nil,
            // The thread, so the system treats successive messages in one
            // conversation as one conversation rather than as unrelated
            // arrivals from the same person.
            conversationIdentifier: conversationID,
            serviceName: nil,
            sender: sender,
            attachments: nil)

        // Donated as *incoming*. Without the donation the system has no record
        // of the conversation and `updating(from:)` produces a banner with no
        // avatar; without `.incoming` the mail would be attributed to the user
        // rather than to whoever wrote it.
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        interaction.donate(completion: nil)

        return (try? content.updating(from: intent)) ?? content
    }

    /// The banner shown when a reply could not be handed to the outbox.
    ///
    /// Carries the typed text in `userInfo` and does **not** auto-dismiss.
    /// Someone who typed three sentences on a lock screen and lost them to a
    /// dropped connection will not type them again, so the words stay
    /// somewhere they can be recovered from.
    static func postReplyFailure(
        accountKey: String,
        threadID: String,
        emailID: String,
        text: String
    ) async {
        let content = UNMutableNotificationContent()

        content.title = NotificationText.replyFailedTitle
        content.body = NotificationText.replyFailedBody
        content.threadIdentifier = accountKey
        content.categoryIdentifier = Identifier.replyFailure
        content.interruptionLevel = .active
        content.userInfo = [
            UserInfo.accountKey: accountKey,
            UserInfo.threadID: threadID,
            UserInfo.emailID: emailID,
            UserInfo.replyText: text,
        ]

        // A distinct identifier, so it never replaces the conversation's own
        // banner and the conversation's own banner never replaces it.
        let request = UNNotificationRequest(
            identifier: "\(accountKey)#\(threadID)#reply-failed",
            content: content,
            trigger: nil)

        try? await UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Withdrawing

    /// Removes banners for conversations that no longer hold unread mail.
    ///
    /// The case this fixes: mail read in the web UI while the phone is on a
    /// desk. Android leaves the row on the lock screen until it is swiped —
    /// a confirmed gap on their side — because it has no way to address a
    /// posted notification by identity. iOS does, so the limitation is not
    /// worth copying.
    ///
    /// - Parameters:
    ///   - accountKey: The account whose delivered banners are considered.
    ///   - stillUnread: Conversation identifiers, in this account, that still
    ///     have something unread. Anything delivered for this account and
    ///     absent from the set is withdrawn.
    static func withdrawRead(accountKey: String, stillUnread: Set<String>) async {
        let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
        let prefix = "\(accountKey)#"

        let stale =
            delivered
            .map(\.request.identifier)
            .filter { $0.hasPrefix(prefix) && stillUnread.contains($0) == false }
            // A failure notification is keyed under the same prefix and holds
            // text that has not been sent yet. Withdrawing it because the
            // thread happens to have been read elsewhere would throw the words
            // away.
            .filter { $0.hasSuffix("#reply-failed") == false }

        guard stale.isEmpty == false else { return }

        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: stale)
    }

    static func withdraw(identifiers: [String]) {
        guard identifiers.isEmpty == false else { return }

        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    /// Everything, for a sign-out. The banners belonged to that credential.
    static func withdrawEverything() {
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    // MARK: - Badge

    /// Sets the badge from the real unread count.
    ///
    /// **Not** from the number of delivered notifications: those are per
    /// conversation and capped, and mail read elsewhere leaves them behind. The
    /// count comes from the same inbox total the widget shows, so the two
    /// cannot disagree.
    static func setBadge(_ count: Int) {
        UNUserNotificationCenter.current().setBadgeCount(max(0, count))
    }
}
