import Foundation
import JMAPKit
import Testing

@testable import PLMailCore

/// The local half of labelling.
///
/// The wire half is one patch and is covered by the encoding tests; what can
/// actually go wrong is here — the optimistic edit drifting from what the
/// server would say, in a way that leaves the picker showing a label the user
/// can no longer take off.
@Suite("Label store")
struct LabelStoreTests {
    private func makeStore() -> SyncStore {
        SyncStore(modelContainer: MailStack.makeContainer(inMemory: true))
    }

    /// Seeds one thread of two messages, both in mailbox "70".
    private func seed(_ store: SyncStore) async throws {
        try await store.upsert(
            emails: [
                email(id: "e1", mailboxes: ["70"]),
                email(id: "e2", mailboxes: ["70"]),
            ],
            threads: [MailThread(id: ThreadID("t1"), emailIDs: [EmailID("e1"), EmailID("e2")])],
            accountKey: "srv/1",
            emailState: nil)
    }

    private func email(id: String, mailboxes: [String]) -> Email {
        var email = Email(id: EmailID(id))
        email.threadID = ThreadID("t1")
        email.receivedAt = UTCDate(Date(timeIntervalSince1970: 1_700_000_000))
        email.mailboxIDs = JMAPIDSet(mailboxes.map { MailboxID($0) })
        return email
    }

    @Test("applying a label adds it to every message in the thread")
    func applies() async throws {
        let store = makeStore()
        try await seed(store)

        try await store.setMailbox(
            true, mailboxID: "73", emailIDs: ["e1", "e2"], accountKey: "srv/1")

        let ids = try await store.mailboxIDs(threadID: "t1", accountKey: "srv/1")

        #expect(ids == ["70", "73"])
    }

    /// A set is idempotent on the wire, so re-applying a label the message
    /// already carries — a double tap, a retry, an undo of an undo — must not
    /// grow the stored array. It is persisted state, so growth is permanent
    /// and unbounded rather than a passing glitch.
    ///
    /// Asserted on the stored array rather than through
    /// ``SyncStore/mailboxIDs(threadID:accountKey:)``, which returns a `Set`
    /// and would report the same answer no matter how many copies were in
    /// there — a test written against it passes with the guard deleted.
    @Test("re-applying a label does not grow the stored list")
    func idempotent() async throws {
        let store = makeStore()
        try await seed(store)

        for _ in 0..<3 {
            try await store.setMailbox(
                true, mailboxID: "73", emailIDs: ["e1"], accountKey: "srv/1")
        }

        let stored = try await store.storedMailboxIDs(emailID: "e1", accountKey: "srv/1")

        #expect(stored.filter { $0 == "73" }.count == 1)
        #expect(stored.count == 2)
    }

    /// The picker shows a label as applied when *any* message carries it,
    /// matching how the list row already treats starred and unread. An
    /// intersection would show nothing applied on a thread where a reply
    /// arrived after the label was set.
    @Test("a thread counts as labelled when only one message carries it")
    func unionNotIntersection() async throws {
        let store = makeStore()
        try await seed(store)

        try await store.setMailbox(
            true, mailboxID: "73", emailIDs: ["e1"], accountKey: "srv/1")

        let ids = try await store.mailboxIDs(threadID: "t1", accountKey: "srv/1")

        #expect(ids.contains("73"))
    }

    @Test("an unknown thread has no mailboxes rather than failing")
    func unknownThread() async throws {
        let store = makeStore()

        let ids = try await store.mailboxIDs(threadID: "nope", accountKey: "srv/1")

        #expect(ids.isEmpty)
    }
}
