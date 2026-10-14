import Foundation
import JMAPKit
import Testing

@testable import PLMailCore

/// *"412 messages, back to 3 March"* — the sentence the accounts screen shows
/// when somebody cannot find an old mail.
///
/// The number is the **device's**, not the server's, and the two are routinely
/// different on an account still backfilling. Getting that wrong turns a
/// correct answer into a bug report, which is why the count is taken from the
/// cache and never from a query.
@Suite("Cached window")
struct CachedWindowTests {
    private func makeStore() -> SyncStore {
        SyncStore(modelContainer: MailStack.makeContainer(inMemory: true))
    }

    private func email(_ id: String, receivedAt: Date) -> Email {
        var email = Email(id: EmailID(rawValue: id))
        email.receivedAt = UTCDate(receivedAt)
        email.threadID = ThreadID(rawValue: "t-\(id)")

        return email
    }

    /// A mailbox connected on the server a minute ago. Not an error, and the
    /// screen must be able to tell it apart from one that has synced.
    @Test("An account with nothing cached reports nothing rather than a date")
    func emptyAccountHasNoWindow() async throws {
        let window = try await makeStore().cachedWindow(accountKey: "srv/a")

        #expect(window.messageCount == 0)
        #expect(window.oldestReceivedAt == nil)
        #expect(window.isEmpty)
    }

    @Test("The count and the oldest date are the account's own")
    func countsOnlyThisAccount() async throws {
        let store = makeStore()
        let march = Date(timeIntervalSince1970: 1_772_000_000)

        try await store.upsert(
            emails: [
                email("1", receivedAt: march),
                email("2", receivedAt: march.addingTimeInterval(86_400)),
            ],
            threads: [], accountKey: "srv/a", emailState: nil)
        try await store.upsert(
            emails: [email("3", receivedAt: march.addingTimeInterval(-86_400))],
            threads: [], accountKey: "srv/b", emailState: nil)

        let a = try await store.cachedWindow(accountKey: "srv/a")

        #expect(a.messageCount == 2)
        #expect(a.oldestReceivedAt == march)

        // The other account's older message must not drag this one's window
        // back — that would report mail the user cannot find here.
        #expect(try await store.cachedWindow(accountKey: "srv/b").messageCount == 1)
    }
}
