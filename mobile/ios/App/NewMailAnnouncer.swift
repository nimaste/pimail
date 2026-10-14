import OSLog
import PLMailCore
import SwiftData

/// Decides what a sync that already happened is worth saying out loud.
///
/// **A consequence of a sync, never a reason to do one.** Nothing here talks
/// to the server: it reads the cache the delta pull has just written and posts
/// banners for what it finds. The background refresh keeps its own fifteen-
/// minute schedule, which is the server's schedule too — this audience runs
/// plMail on a Raspberry Pi with one PHP worker pool, and a notification
/// feature that pulled more often would be felt by every other client on that
/// machine.
@MainActor
final class NewMailAnnouncer {
    private let logger = Logger(subsystem: "de.plmail", category: "notify")

    private let reader: NewMailReader
    private let notified: NotifiedMessageStore
    private let preferences: NotificationPreferences

    init(
        container: ModelContainer,
        notified: NotifiedMessageStore = NotifiedMessageStore(),
        preferences: NotificationPreferences = .shared
    ) {
        reader = NewMailReader(modelContainer: container)
        self.notified = notified
        self.preferences = preferences
    }

    /// One pass over what the cache now holds.
    ///
    /// - Parameters:
    ///   - accounts: Every account, so an account with nothing new still gets
    ///     its stale banners withdrawn.
    ///   - mailboxes: Every account's mailboxes, for the scope rules. Passed
    ///     in rather than re-read because `MailSyncService` has them already
    ///     and a second fetch would be a second pass over the same rows.
    ///   - unreadCount: What the badge should say. The inbox unread total,
    ///     which is the number the widget shows — the two must agree or one of
    ///     them is lying.
    func announce(
        accounts: [AccountSnapshot],
        mailboxes: [MailboxSnapshot],
        unreadCount: Int
    ) async {
        // Checked first, and nothing is claimed when it fails. `add(_:)`
        // accepts a request and silently drops it without permission, so a
        // pass that ran anyway would record every message as announced — and
        // granting permission a week later would then start from silence.
        guard await MailNotifications.isAuthorized() else { return }

        let policy = preferences.policy
        let since = Date.now.addingTimeInterval(-NewMailReader.lookback)
        var fresh: [NewMailMessage] = []

        for account in accounts {
            let candidates: [NewMailMessage]

            do {
                candidates = try await reader.candidates(
                    accountKey: account.accountKey,
                    accountName: account.displayName,
                    since: since)
            } catch {
                // One account's failure is not the others'. A banner nobody
                // gets is a smaller problem than a pass that stops halfway.
                logger.error(
                    "\(account.accountKey, privacy: .public): \(error, privacy: .public)")
                continue
            }

            if await notified.isPrimed(accountKey: account.accountKey) == false {
                // The first pass this account has ever had: a fresh sign-in,
                // or the upgrade that introduced notifications to a device
                // that already holds a month of mail. Every unread message
                // looks new and none of it is news, so it is claimed in
                // silence. Claiming the *unfiltered* candidates matters — a
                // message in a muted label that is unmuted tomorrow must not
                // then be announced as though it had just arrived.
                await notified.claim(candidates.map(\.id))
                await notified.markPrimed(accountKey: account.accountKey)
            } else {
                let permitted = NewMailAnnouncement.permitted(
                    candidates, mailboxes: mailboxes, policy: policy)

                // Claim, then announce what the claim returned. Two syncs
                // landing together — a silent push and the periodic refresh —
                // is the normal case, and this is the only thing that stops
                // both of them announcing the same message.
                let claimed = Set(await notified.claim(permitted.map(\.id)))

                fresh += permitted.filter { claimed.contains($0.id) }
            }

            await withdrawRead(accountKey: account.accountKey)
        }

        await MailNotifications.post(NewMailAnnouncement.group(fresh))
        MailNotifications.setBadge(unreadCount)
    }

    /// Takes down banners for conversations that have been read elsewhere.
    private func withdrawRead(accountKey: String) async {
        do {
            let stillUnread = try await reader.unreadConversationIdentifiers(
                accountKey: accountKey)

            await MailNotifications.withdrawRead(
                accountKey: accountKey, stillUnread: stillUnread)
        } catch {
            logger.error("Could not withdraw read banners: \(error, privacy: .public)")
        }
    }

    /// Forgets everything, for a deliberate sign-out.
    ///
    /// The banners and the dedupe record both belonged to that credential.
    /// Carrying the record forward would silence the next account's mail
    /// wherever the two servers issued the same message id — which they will,
    /// because ids are only unique within an account.
    func forgetEverything() async {
        await notified.reset()
        MailNotifications.withdrawEverything()
        MailNotifications.setBadge(0)
    }
}
