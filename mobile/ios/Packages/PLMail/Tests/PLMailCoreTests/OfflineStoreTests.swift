import Foundation
import JMAPKit
import Testing

@testable import PLMailCore

/// The store queries the offline work needs: which lists exist, how to rewrite
/// them, and which messages still have no body on this device.
@Suite("Offline store queries")
struct OfflineStoreTests {
    private func makeStore() -> SyncStore {
        SyncStore(modelContainer: MailStack.makeContainer(inMemory: true))
    }

    private func email(
        id: String, thread: String, at seconds: TimeInterval, mailboxes: [String]
    )
        -> Email
    {
        var email = Email(id: EmailID(id))
        email.threadID = ThreadID(thread)
        email.receivedAt = UTCDate(Date(timeIntervalSince1970: seconds))
        email.mailboxIDs = JMAPIDSet(mailboxes.map { MailboxID($0) })

        return email
    }

    private func seed(_ store: SyncStore) async throws {
        try await store.upsert(
            emails: [
                email(id: "e1", thread: "t1", at: 1_700_000_000, mailboxes: ["70"]),
                email(id: "e2", thread: "t2", at: 1_600_000_000, mailboxes: ["70"]),
            ],
            threads: [
                MailThread(id: ThreadID("t1"), emailIDs: [EmailID("e1")]),
                MailThread(id: ThreadID("t2"), emailIDs: [EmailID("e2")]),
            ],
            accountKey: "srv/1",
            emailState: nil)
    }

    // MARK: - Bodies

    /// Newest first because that is what a person opens on a train, and limited
    /// because the prefetcher's whole point is a budget on a server that is
    /// often a Raspberry Pi.
    @Test("messages with no body come back newest first, within the budget")
    func withoutBody() async throws {
        let store = makeStore()
        try await seed(store)

        #expect(
            try await store.messagesWithoutBody(accountKey: "srv/1", limit: 10) == ["e1", "e2"])
        #expect(try await store.messagesWithoutBody(accountKey: "srv/1", limit: 1) == ["e1"])
    }

    /// Without this marker the prefetcher re-considers the same messages on
    /// every run forever: a message with no body is indistinguishable from one
    /// never fetched, so it eats the budget every time and the mail behind it is
    /// never prefetched at all.
    @Test("a message recorded as having no body stops being a candidate")
    func recordsMissingBody() async throws {
        let store = makeStore()
        try await seed(store)

        try await store.recordMissingBody(emailIDs: ["e1"], accountKey: "srv/1")

        #expect(try await store.messagesWithoutBody(accountKey: "srv/1", limit: 10) == ["e2"])
    }

    /// A real body must not be replaced by the tombstone — that would throw
    /// away a message the user can currently read offline.
    @Test("recording a missing body never overwrites one that is already there")
    func doesNotOverwrite() async throws {
        let store = makeStore()
        try await seed(store)

        var withBody = email(id: "e1", thread: "t1", at: 1_700_000_000, mailboxes: ["70"])
        withBody.bodyValues = [Email.SyntheticPart.text: BodyValue(value: "Hello")]

        try await store.storeReaderContent([withBody], accountKey: "srv/1")
        try await store.recordMissingBody(emailIDs: ["e1"], accountKey: "srv/1")

        let message = try await store.message(emailID: "e1", accountKey: "srv/1")

        #expect(message?.textBody == "Hello")
    }

    // MARK: - Projection

    @Test("only the feeds this account has actually paged come back")
    func pagedFeeds() async throws {
        let store = makeStore()
        try await seed(store)

        try await store.appendFeedRows(
            [FeedRow(threadID: "t1", emailID: "e1", sortDate: Date(timeIntervalSince1970: 1))],
            feedID: FeedID.unified(.inbox).rawValue,
            accountKey: "srv/1",
            cursor: FeedCursorSnapshot(
                lastSortDate: Date(timeIntervalSince1970: 1), boundaryIDs: ["e1"],
                isExhausted: false)
        )

        let paged = try await store.pagedFeeds(accountKey: "srv/1")

        #expect(paged.map(\.feedID) == [FeedID.unified(.inbox).rawValue])
        #expect(paged.first?.cursor.lastSortDate == Date(timeIntervalSince1970: 1))
        #expect(try await store.pagedFeeds(accountKey: "srv/2").isEmpty)
    }

    /// The union across the conversation, and the row's own newest message —
    /// the two things a projection decision is made from.
    @Test("a thread projection carries every mailbox its messages are in")
    func threadProjections() async throws {
        let store = makeStore()
        try await seed(store)

        try await store.setMailbox(
            true, mailboxID: "73", emailIDs: ["e1"], accountKey: "srv/1")

        let projections = try await store.threadProjections(
            threadIDs: ["t1"], accountKey: "srv/1")

        #expect(projections.first?.mailboxIDs == ["70", "73"])
        #expect(projections.first?.newestEmailID == "e1")
    }

    @Test(
        "a projection inserts a row where the conversation now belongs and drops it where it does not"
    )
    func appliesProjection() async throws {
        let store = makeStore()
        try await seed(store)

        let inbox = FeedID.unified(.inbox).rawValue

        try await store.appendFeedRows(
            [FeedRow(threadID: "t1", emailID: "e1", sortDate: Date(timeIntervalSince1970: 5))],
            feedID: inbox,
            accountKey: "srv/1",
            cursor: FeedCursorSnapshot()
        )

        try await store.applyProjection([
            FeedProjectionChange(
                feedID: inbox, accountKey: "srv/1", threadID: "t1", kind: .remove),
            FeedProjectionChange(
                feedID: inbox, accountKey: "srv/1", threadID: "t2",
                kind: .insert(sortDate: Date(timeIntervalSince1970: 9), emailID: "e2")),
        ])

        let rows = try await store.feedRows(feedID: inbox)

        #expect(rows.map(\.threadID) == ["t2"])
    }

    /// The queue may only hold the user-scoped id, because a binding is valid
    /// against one account and can be recreated with a different number when a
    /// label is deleted and remade.
    @Test("a binding can be translated back to the label it belongs to")
    func labelIDFromBinding() async throws {
        let store = makeStore()

        var mailbox = Mailbox(id: MailboxID("73"))
        mailbox.name = "Work"
        mailbox.labelID = LabelID("lbl-work")

        try await store.replaceMailboxes(
            [mailbox], accountKey: "srv/1", state: StateToken(rawValue: "1"))

        #expect(
            try await store.labelID(mailboxID: "73", accountKey: "srv/1") == LabelID("lbl-work"))
        #expect(try await store.labelID(mailboxID: "70", accountKey: "srv/1") == nil)
    }
}
