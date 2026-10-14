import Foundation
import JMAPKit
import Testing

@testable import PLMailCore

/// A fresh, isolated defaults suite per test.
///
/// `.standard` would leak state between tests *and* into whatever else is
/// running on the host, and a dedupe test that passes only when it runs first
/// is worse than no dedupe test.
private func scratchSuite() -> String { "notifications-\(UUID().uuidString)" }

private func mailbox(
    _ id: String,
    name: String,
    role: MailboxRole? = nil,
    parent: String? = nil,
    account: String = "server/a"
) -> MailboxSnapshot {
    MailboxSnapshot(
        accountKey: account,
        mailboxID: MailboxID(id),
        labelID: nil,
        name: name,
        role: role,
        parentID: parent.map { MailboxID($0) },
        color: nil,
        unreadThreads: 0,
        totalThreads: 0)
}

private func message(
    _ emailID: String,
    thread: String = "t1",
    account: String = "server/a",
    mailboxes: Set<String> = ["inbox"],
    receivedAt: Date = .now
) -> NewMailMessage {
    NewMailMessage(
        accountKey: account,
        accountName: "Personal",
        threadID: thread,
        emailID: emailID,
        senderName: "Ada",
        senderAddress: "ada@example.org",
        subject: "Hello",
        preview: "Hello there",
        receivedAt: receivedAt,
        mailboxIDs: mailboxes)
}

@Suite("Notification scopes")
struct NotifyScopeTests {
    @Test("mail in Sent is never announced, even when it is also in Inbox")
    func sentVetoesInbox() {
        let mailboxes = [
            mailbox("inbox", name: "Inbox", role: .inbox),
            mailbox("sent", name: "Sent", role: .sent),
        ]

        let scopes = NotifyScopes.scopes(
            forMailboxIDs: ["inbox", "sent"], in: mailboxes)

        #expect(scopes.isEmpty)
    }

    @Test("every excluded role vetoes on its own", arguments: NotifyScopes.neverNotifiableRoles)
    func everyExcludedRoleVetoes(role: MailboxRole) {
        let mailboxes = [
            mailbox("inbox", name: "Inbox", role: .inbox),
            mailbox("x", name: "Somewhere", role: role),
        ]

        #expect(NotifyScopes.scopes(forMailboxIDs: ["inbox", "x"], in: mailboxes).isEmpty)
    }

    @Test("a nested label is keyed by its path, not its leaf name")
    func nestedLabelUsesPath() {
        let mailboxes = [
            mailbox("work", name: "Work"),
            mailbox("receipts", name: "Receipts", parent: "work"),
        ]

        let scopes = NotifyScopes.scopes(forMailboxIDs: ["receipts"], in: mailboxes)

        #expect(scopes.map(\.key) == ["label:Work/Receipts"])
        #expect(scopes.map(\.title) == ["Work/Receipts"])
    }

    @Test("a mailbox whose parent is missing keeps its own name rather than vanishing")
    func unresolvableParentStillProducesAScope() {
        let mailboxes = [mailbox("receipts", name: "Receipts", parent: "gone")]

        #expect(
            NotifyScopes.scopes(forMailboxIDs: ["receipts"], in: mailboxes).map(\.key)
                == ["label:Receipts"])
    }

    @Test("only Inbox is on by default")
    func onlyInboxDefaultsOn() {
        let mailboxes = [
            mailbox("inbox", name: "Inbox", role: .inbox),
            mailbox("news", name: "Newsletters"),
        ]

        let selectable = NotifyScopes.selectable(in: mailboxes)

        #expect(selectable.count == 2)
        #expect(selectable.first { $0.title == "Inbox" }?.isNotifiableByDefault == true)
        #expect(selectable.first { $0.title == "Newsletters" }?.isNotifiableByDefault == false)
    }

    @Test("the settings list never offers a toggle that could do nothing")
    func selectableExcludesNeverNotifiableRoles() {
        let mailboxes = [
            mailbox("inbox", name: "Inbox", role: .inbox),
            mailbox("trash", name: "Trash", role: .trash),
            mailbox("sent", name: "Sent", role: .sent),
        ]

        #expect(NotifyScopes.selectable(in: mailboxes).map(\.title) == ["Inbox"])
    }
}

@Suite("Notification policy")
struct NotificationPolicyTests {
    private let inbox = NotifyScope(
        key: "label:Inbox", title: "Inbox", isNotifiableByDefault: true)
    private let newsletters = NotifyScope(
        key: "label:Newsletters", title: "Newsletters", isNotifiableByDefault: false)

    @Test("a brand-new account speaks without anyone opening the settings")
    func newAccountSpeaks() {
        let policy = NotificationPolicy()

        #expect(policy.allows(accountKey: "server/never-seen", scopes: [inbox]))
    }

    @Test("a muted account stays silent whatever its labels say")
    func mutedAccountIsSilent() {
        let policy = NotificationPolicy(mutedAccounts: ["server/a"])

        #expect(policy.allows(accountKey: "server/a", scopes: [inbox]) == false)
        #expect(policy.allows(accountKey: "server/b", scopes: [inbox]))
    }

    @Test("a label nobody has said anything about is silent unless it is the inbox")
    func unsetLabelIsSilent() {
        let policy = NotificationPolicy()

        #expect(policy.allows(accountKey: "server/a", scopes: [newsletters]) == false)
    }

    @Test("switching a label on gives it a voice")
    func explicitEnableSpeaks() {
        let policy = NotificationPolicy(enabledScopes: ["label:Newsletters"])

        #expect(policy.allows(accountKey: "server/a", scopes: [newsletters]))
    }

    @Test("muting a label wins over the inbox it also sits in")
    func explicitDisableBeatsDefault() {
        let policy = NotificationPolicy(disabledScopes: ["label:Newsletters"])

        #expect(policy.allows(accountKey: "server/a", scopes: [inbox, newsletters]) == false)
    }

    @Test("a disable wins over an enable on another of the message's labels")
    func disableBeatsEnable() {
        let policy = NotificationPolicy(
            enabledScopes: ["label:Newsletters"], disabledScopes: ["label:Inbox"])

        #expect(policy.allows(accountKey: "server/a", scopes: [inbox, newsletters]) == false)
    }

    @Test("a message in no scope at all is silent")
    func noScopesIsSilent() {
        #expect(NotificationPolicy().allows(accountKey: "server/a", scopes: []) == false)
    }

    @Test("never said, on and off are three different answers")
    func choiceIsTriState() {
        let policy = NotificationPolicy(
            enabledScopes: ["label:A"], disabledScopes: ["label:B"])

        #expect(policy.choice(forScope: "label:A") == .on)
        #expect(policy.choice(forScope: "label:B") == .off)
        #expect(policy.choice(forScope: "label:C") == .unset)
    }
}

@Suite("Notification preferences")
@MainActor
struct NotificationPreferencesTests {
    @Test("muting an account survives a relaunch")
    func mutingPersists() throws {
        let defaults = try #require(UserDefaults(suiteName: scratchSuite()))
        let first = NotificationPreferences(defaults: defaults)

        first.setMuted(true, accountKey: "server/a")

        #expect(NotificationPreferences(defaults: defaults).isMuted(accountKey: "server/a"))
    }

    @Test("switching a label off leaves it in exactly one of the two sets")
    func disableClearsEnable() throws {
        let preferences = NotificationPreferences(
            defaults: try #require(UserDefaults(suiteName: scratchSuite())))

        preferences.setEnabled(true, scopeKey: "label:News")
        preferences.setEnabled(false, scopeKey: "label:News")

        #expect(preferences.policy.enabledScopes.contains("label:News") == false)
        #expect(preferences.policy.disabledScopes.contains("label:News"))
        #expect(preferences.choice(forScope: "label:News") == .off)
    }

    @Test("clearing a choice puts the label back on the default")
    func clearingRestoresDefault() throws {
        let preferences = NotificationPreferences(
            defaults: try #require(UserDefaults(suiteName: scratchSuite())))

        preferences.setEnabled(false, scopeKey: "label:News")
        preferences.clearChoice(forScope: "label:News")

        #expect(preferences.choice(forScope: "label:News") == .unset)
    }
}

@Suite("Notified message store")
struct NotifiedMessageStoreTests {
    @Test("a message is only ever claimed once")
    func claimIsExactlyOnce() async {
        let store = NotifiedMessageStore(suiteName: scratchSuite())

        #expect(await store.claim(["a", "b"]) == ["a", "b"])
        #expect(await store.claim(["b", "c"]) == ["c"])
    }

    @Test("a message announced before a relaunch is not announced after one")
    func claimSurvivesRelaunch() async {
        let suite = scratchSuite()

        await NotifiedMessageStore(suiteName: suite).claim(["a"])

        #expect(await NotifiedMessageStore(suiteName: suite).claim(["a", "b"]) == ["b"])
    }

    @Test("two syncs landing together announce a message once between them")
    func concurrentClaimsDoNotDouble() async {
        let store = NotifiedMessageStore(suiteName: scratchSuite())
        let ids = (0..<200).map { "m\($0)" }

        async let first = store.claim(ids)
        async let second = store.claim(ids)

        let claimed = await first + second

        #expect(claimed.count == ids.count)
        #expect(Set(claimed).count == ids.count)
    }

    @Test("the record is bounded, and forgets the oldest first")
    func capacityTrimsOldestFirst() async {
        let store = NotifiedMessageStore(suiteName: scratchSuite(), capacity: 3)

        await store.claim(["a", "b", "c", "d"])

        #expect(await store.hasAnnounced("a") == false)
        #expect(await store.hasAnnounced("d"))
    }

    @Test("an account is primed once, and only once")
    func primingIsRecordedPerAccount() async {
        let suite = scratchSuite()
        let store = NotifiedMessageStore(suiteName: suite)

        #expect(await store.isPrimed(accountKey: "server/a") == false)
        await store.markPrimed(accountKey: "server/a")
        #expect(await store.isPrimed(accountKey: "server/a"))
        // A second account connected weeks later still gets its silent first
        // pass rather than announcing a month of cached mail.
        #expect(await store.isPrimed(accountKey: "server/b") == false)
        #expect(await NotifiedMessageStore(suiteName: suite).isPrimed(accountKey: "server/a"))
    }

    @Test("signing out forgets everything, so the next account is not silenced by id collision")
    func resetForgetsEverything() async {
        let suite = scratchSuite()
        let store = NotifiedMessageStore(suiteName: suite)

        await store.claim(["a"])
        await store.markPrimed(accountKey: "server/a")
        await store.reset()

        #expect(await store.hasAnnounced("a") == false)
        #expect(await store.isPrimed(accountKey: "server/a") == false)
        #expect(await NotifiedMessageStore(suiteName: suite).hasAnnounced("a") == false)
    }
}

@Suite("New mail announcements")
struct NewMailAnnouncementTests {
    @Test("a thread that gained five replies is one banner, not five")
    func oneBannerPerConversation() {
        let messages = (0..<5).map {
            message("m\($0)", receivedAt: Date(timeIntervalSince1970: Double($0)))
        }

        let grouped = NewMailAnnouncement.group(messages)

        #expect(grouped.count == 1)
        #expect(grouped[0].messageCount == 5)
        #expect(grouped[0].id == "server/a#t1")
        #expect(grouped[0].latest.emailID == "m4")
    }

    @Test("the limit keeps the mail that just arrived, not Friday's")
    func limitKeepsTheNewest() {
        let messages = (0..<10).map {
            message(
                "m\($0)", thread: "t\($0)",
                receivedAt: Date(timeIntervalSince1970: Double($0)))
        }

        let grouped = NewMailAnnouncement.group(messages, limit: 3)

        #expect(grouped.map(\.threadID) == ["t7", "t8", "t9"])
    }

    @Test("scopes are resolved against the message's own account")
    func scopesAreResolvedPerAccount() {
        // Both accounts have a mailbox called "inbox", and only one of them is
        // the Inbox. Resolving against the wrong account's list would announce
        // mail from a label the user never enabled.
        let mailboxes = [
            mailbox("inbox", name: "Inbox", role: .inbox, account: "server/a"),
            mailbox("inbox", name: "Newsletters", account: "server/b"),
        ]

        let permitted = NewMailAnnouncement.permitted(
            [
                message("m1", account: "server/a"),
                message("m2", account: "server/b"),
            ],
            mailboxes: mailboxes,
            policy: NotificationPolicy())

        #expect(permitted.map(\.emailID) == ["m1"])
    }

    @Test("a muted account contributes nothing to a pass that still announces the others")
    func mutedAccountDropsOutOfAMixedPass() {
        let mailboxes = [
            mailbox("inbox", name: "Inbox", role: .inbox, account: "server/a"),
            mailbox("inbox2", name: "Inbox", role: .inbox, account: "server/b"),
        ]

        let permitted = NewMailAnnouncement.permitted(
            [
                message("m1", account: "server/a"),
                message("m2", account: "server/b", mailboxes: ["inbox2"]),
            ],
            mailboxes: mailboxes,
            policy: NotificationPolicy(mutedAccounts: ["server/a"]))

        #expect(permitted.map(\.emailID) == ["m2"])
    }

    @Test("a sender with neither a name nor an address still has a title")
    func senderNameIsNeverBlank() {
        let bounced = NewMailMessage(
            accountKey: "server/a",
            accountName: "Personal",
            threadID: "t1",
            emailID: "m1",
            receivedAt: .now)

        #expect(bounced.senderDisplayName.isEmpty == false)
        #expect(bounced.subjectDisplayText.isEmpty == false)
    }
}

@Suite("Notification replies")
struct NotificationReplyTests {
    private func original(
        from: String? = "ada@example.org",
        messageID: String? = "<one@example.org>"
    ) -> MessageSnapshot {
        MessageSnapshot(
            emailID: "m1",
            accountKey: "server/a",
            blobID: nil,
            subject: "Re: Lunch",
            fromName: "Ada",
            fromAddress: from,
            to: [],
            cc: [],
            receivedAt: .now,
            messageID: messageID,
            references: ["<zero@example.org>"],
            preview: "",
            isSeen: false,
            isFlagged: false,
            isDraft: false,
            htmlBody: nil,
            textBody: nil,
            hasBody: false,
            attachments: [],
            inlineParts: [])
    }

    private let identity = IdentitySnapshot(
        id: IdentityID("i1"), name: "Me", email: "me@example.org")

    @Test("a lock-screen reply keeps the conversation together")
    func replyCarriesThreadingHeaders() throws {
        let pending = try #require(
            NotificationReply.pendingMessage(
                replyingTo: original(),
                identity: identity,
                accountID: AccountID("a"),
                text: "On my way"))

        #expect(pending.to.map(\.email) == ["ada@example.org"])
        #expect(pending.inReplyTo == ["<one@example.org>"])
        #expect(pending.references == ["<zero@example.org>", "<one@example.org>"])
        #expect(pending.body == "On my way")
        // Not "Re: Re: Lunch". The prefix rules are the composer's own.
        #expect(pending.subject == "Re: Lunch")
    }

    @Test("a message with nobody to reply to is refused rather than queued")
    func noSenderIsRefused() {
        #expect(
            NotificationReply.pendingMessage(
                replyingTo: original(from: nil),
                identity: identity,
                accountID: AccountID("a"),
                text: "Hello") == nil)
    }

    @Test("whitespace typed by a sleeve is not a message")
    func blankReplyIsRefused() {
        #expect(
            NotificationReply.pendingMessage(
                replyingTo: original(),
                identity: identity,
                accountID: AccountID("a"),
                text: "   \n ") == nil)
    }

    @Test("an original with no Message-ID still sends, without threading headers")
    func missingMessageIDStillSends() throws {
        let pending = try #require(
            NotificationReply.pendingMessage(
                replyingTo: original(messageID: nil),
                identity: identity,
                accountID: AccountID("a"),
                text: "Yes"))

        #expect(pending.inReplyTo == nil)
        #expect(pending.references == nil)
    }
}

@Suite("Notification wording")
struct NotificationTextTests {
    /// The German table, loaded directly — see `LocalizationTests` for why
    /// `String(localized:locale:)` cannot be used to check this.
    private var germanBundle: Bundle {
        get throws {
            let path = try #require(Bundle.module.path(forResource: "de", ofType: "lproj"))

            return try #require(Bundle(path: path))
        }
    }

    /// The bug Android shipped: a German device read a German inbox out in
    /// English, on a lock screen, where there is nowhere else to look.
    @Test(
        "notification wording resolves in German",
        arguments: [
            ("Unknown sender", "Unbekannter Absender"),
            ("(no subject)", "(kein Betreff)"),
            ("Mark as read", "Als gelesen markieren"),
            ("Reply", "Antworten"),
            ("Send", "Senden"),
            ("Try again", "Erneut versuchen"),
            ("Your reply hasn't been sent", "Deine Antwort wurde noch nicht gesendet"),
        ])
    func wordingInGerman(key: String.LocalizationValue, expected: String) throws {
        #expect(String(localized: key, bundle: try germanBundle) == expected)
    }

    @Test("the message count is a translated format string, not an English literal")
    func countInGerman() throws {
        let format = String(localized: "%lld new messages", bundle: try germanBundle)

        #expect(String(format: format, 3) == "3 neue Nachrichten")
    }
}
