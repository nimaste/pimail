import Foundation
import JMAPKit
import Testing

@testable import PLMailCore

/// The rules behind the inbox tabs, which are the ones that go wrong quietly:
/// a category feed that forgets its inbox binding shows the bin's promotions,
/// and one that folds unclassified mail into Primary puts mail on the phone
/// that the browser's own Primary tab does not have.
@Suite("Inbox categories")
struct InboxCategoryTests {
    private static let inbox = MailboxSnapshot(
        accountKey: "srv/1", mailboxID: MailboxID("70"), labelID: nil, name: "Inbox",
        role: .inbox, parentID: nil, color: nil, unreadThreads: 0, totalThreads: 0)

    private static let archive = MailboxSnapshot(
        accountKey: "srv/1", mailboxID: MailboxID("71"), labelID: nil, name: "Archive",
        role: .archive, parentID: nil, color: nil, unreadThreads: 0, totalThreads: 0)

    // MARK: - The feed id

    /// The id is written to a `StoredFeedCursor` as a bare string and read back
    /// by the projection. A category that could not survive the round trip
    /// would be a list the projection cannot recognise, and a conversation
    /// archived in the browser would be removed from every list except that
    /// one.
    @Test("every category feed id survives the round trip through a string")
    func roundTrips() throws {
        for category in MessageCategory.allCases {
            let feed = FeedID.category(category)

            #expect(FeedID(rawValue: feed.rawValue) == feed)
            #expect(feed.category == category)
        }
    }

    /// A stored cursor naming a category this build has never heard of must
    /// resolve to nothing rather than to an unknown list the projection then
    /// tries to reconcile.
    @Test("an unknown category token is not a feed")
    func refusesUnknownToken() {
        #expect(FeedID(rawValue: "category:parcels") == nil)
    }

    /// Categories narrow the unified inbox and nothing else. A single account's
    /// inbox mailbox is deliberately excluded: the filter is cross-account by
    /// construction, so offering it there would quietly change which accounts
    /// the list covers.
    @Test("only the unified inbox offers categories")
    func onlyUnifiedInbox() {
        #expect(FeedID.unified(.inbox).isUnifiedInbox)
        #expect(FeedID.unified(.archive).isUnifiedInbox == false)
        #expect(
            FeedID.mailbox(accountKey: "srv/1", mailboxID: MailboxID("70")).isUnifiedInbox == false)
        #expect(FeedID.category(.promotions).isUnifiedInbox == false)
    }

    // MARK: - Projection

    /// The failure this guards: a conversation keeps its category after it is
    /// archived, so a projection that tested the category alone would leave the
    /// row on a list that claims to be a slice of the inbox.
    @Test("a conversation out of the Inbox is out of its category feed too")
    func categoryHangsOffTheInboxBinding() {
        let inInbox = FeedProjection.belongs(
            in: .category(.promotions),
            mailboxIDs: ["70"],
            accountKey: "srv/1",
            mailboxes: [Self.inbox, Self.archive],
            category: .promotions)

        let archived = FeedProjection.belongs(
            in: .category(.promotions),
            mailboxIDs: ["71"],
            accountKey: "srv/1",
            mailboxes: [Self.inbox, Self.archive],
            category: .promotions)

        #expect(inInbox == true)
        #expect(archived == false)
    }

    /// **Nil is not Primary.** The server's own inbox query does not fold
    /// unclassified mail into Primary, and a client that did would show mail on
    /// its Primary tab that the browser's does not have — the two clients would
    /// then disagree about the same mailbox.
    @Test("mail the classifier never saw belongs to no tab, including Primary")
    func nilIsNotPrimary() {
        for category in MessageCategory.allCases {
            #expect(
                FeedProjection.belongs(
                    in: .category(category),
                    mailboxIDs: ["70"],
                    accountKey: "srv/1",
                    mailboxes: [Self.inbox],
                    category: nil) == false)
        }
    }

    /// An account with no Inbox binding contributes no rows to a category list
    /// and never did. Answering "does not belong" would be true but useless,
    /// and would invite a delete of rows this account cannot own.
    @Test("an account with no Inbox is left alone rather than emptied")
    func noInboxBindingIsNotARemoval() {
        #expect(
            FeedProjection.belongs(
                in: .category(.social),
                mailboxIDs: ["71"],
                accountKey: "srv/1",
                mailboxes: [Self.archive],
                category: .social) == nil)
    }

    /// A conversation whose category changed — the classifier revised it, or a
    /// reply arrived and the most-recent-wins resolution moved — leaves the tab
    /// it was on.
    @Test("a conversation reclassified elsewhere leaves the tab it was on")
    func reclassificationRemoves() {
        #expect(
            FeedProjection.belongs(
                in: .category(.promotions),
                mailboxIDs: ["70"],
                accountKey: "srv/1",
                mailboxes: [Self.inbox],
                category: .updates) == false)
    }

    // MARK: - The store

    private func makeStore() -> SyncStore {
        SyncStore(modelContainer: MailStack.makeContainer(inMemory: true))
    }

    private func email(id: String, thread: String) -> Email {
        var email = Email(id: EmailID(id))
        email.threadID = ThreadID(thread)
        email.receivedAt = UTCDate(Date(timeIntervalSince1970: 1_700_000_000))
        email.mailboxIDs = JMAPIDSet([MailboxID("70")])

        return email
    }

    /// Five permanently empty tabs above a working inbox reads as mail having
    /// gone missing, so the control is withheld until there is evidence the
    /// classifier has ever run.
    @Test("a server that classifies nothing is detected as classifying nothing")
    func detectsAnUnclassifiedServer() async throws {
        let store = makeStore()

        try await store.upsert(
            emails: [email(id: "e1", thread: "t1")],
            threads: [MailThread(id: ThreadID("t1"), emailIDs: [EmailID("e1")])],
            accountKey: "srv/1",
            emailState: nil)

        #expect(try await store.hasCategorisedThreads() == false)

        try await store.upsert(
            emails: [email(id: "e2", thread: "t2")],
            threads: [
                MailThread(
                    id: ThreadID("t2"), emailIDs: [EmailID("e2")], category: .promotions)
            ],
            accountKey: "srv/1",
            emailState: nil)

        #expect(try await store.hasCategorisedThreads())
    }

    /// The category and the marker are written from `Thread/get`, and both have
    /// to reach the projection — the tab feeds are reconciled from that value
    /// and nothing else reads it.
    @Test("Thread/get's category and New marker are stored and projected")
    func storesThreadExtensions() async throws {
        let store = makeStore()

        try await store.upsert(
            emails: [email(id: "e1", thread: "t1")],
            threads: [
                MailThread(
                    id: ThreadID("t1"), emailIDs: [EmailID("e1")], category: .forums, isNew: true)
            ],
            accountKey: "srv/1",
            emailState: nil)

        let projection = try #require(
            try await store.threadProjections(threadIDs: ["t1"], accountKey: "srv/1").first)

        #expect(projection.category == .forums)
        #expect(try await store.newMarkers(threadIDs: ["t1"], accountKey: "srv/1") == ["t1"])
    }

    /// A page that fetched emails without their threads must not be read as the
    /// classifier having changed its mind and emptied every tab — nil is a
    /// meaningful category, so there is no sentinel left to mean "this batch
    /// said nothing".
    @Test("a page carrying no thread does not clear the category or the marker")
    func silenceIsNotAChange() async throws {
        let store = makeStore()

        try await store.upsert(
            emails: [email(id: "e1", thread: "t1")],
            threads: [
                MailThread(
                    id: ThreadID("t1"), emailIDs: [EmailID("e1")], category: .social, isNew: true)
            ],
            accountKey: "srv/1",
            emailState: nil)

        try await store.upsert(
            emails: [email(id: "e1", thread: "t1")],
            threads: [],
            accountKey: "srv/1",
            emailState: nil)

        let projection = try #require(
            try await store.threadProjections(threadIDs: ["t1"], accountKey: "srv/1").first)

        #expect(projection.category == .social)
        #expect(try await store.newMarkers(threadIDs: ["t1"], accountKey: "srv/1") == ["t1"])
    }

    // MARK: - The wire

    /// The condition is thread-scoped and server-side. Compiling it wrong is
    /// invisible until a tab comes back empty, because the server answers an
    /// unknown token with `invalidArguments` rather than with no rows.
    @Test("the category filter compiles to threadCategory beside the inbox")
    func filterShape() throws {
        let filter = EmailFilter.and([
            .inMailbox(MailboxID("70")), .threadCategory(.promotions),
        ])

        let body = try #require(
            String(data: try JSONEncoder().encode(filter), encoding: .utf8))

        #expect(body.contains("\"threadCategory\":\"promotions\""))
        #expect(body.contains("inMailbox"))
    }

    /// The vocabulary is closed server-side, so a token outside it is not a
    /// filter value — it is a value that names nothing.
    @Test("an unrecognised wire token is no category rather than a new one")
    func closedVocabulary() {
        #expect(MessageCategory(wire: "promotions") == .promotions)
        #expect(MessageCategory(wire: "parcels") == nil)
        #expect(MessageCategory(wire: nil) == nil)
    }
}
