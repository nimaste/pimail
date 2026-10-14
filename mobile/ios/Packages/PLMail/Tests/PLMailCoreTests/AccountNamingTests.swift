import Foundation
import JMAPKit
import Testing

@testable import PLMailCore

/// What a second account is called in the list.
///
/// This only matters once there are two accounts, which is exactly why it went
/// unnoticed: with one account the label is hidden entirely. On a two-account
/// inbox every row from the nameless one was tagged `Mailbox 1119` — an
/// internal database id, shown to the user as the only thing distinguishing
/// their work mail from their personal mail.
@Suite("Account naming")
struct AccountNamingTests {
    private func makeStore() -> SyncStore {
        SyncStore(modelContainer: MailStack.makeContainer(inMemory: true))
    }

    /// `name` is not required to be useful — plMail names a JMAP account after
    /// the mail account it syncs, and that field can be empty.
    private func session(accountName: String) throws -> Session {
        let json = Data(
            """
            {
              "capabilities": {
                "urn:ietf:params:jmap:core": {
                  "maxSizeUpload": 50000000, "maxConcurrentUpload": 4,
                  "maxSizeRequestObject": 10000000, "maxConcurrentRequests": 4,
                  "maxCallsInRequest": 32, "maxObjectsInGet": 500,
                  "maxObjectsInSet": 500, "collationAlgorithms": []
                }
              },
              "accounts": {
                "1119": {
                  "name": "\(accountName)",
                  "isPersonal": true,
                  "isReadOnly": false,
                  "accountCapabilities": { "urn:ietf:params:jmap:mail": {} }
                }
              },
              "primaryAccounts": { "urn:ietf:params:jmap:mail": "1119" },
              "username": "someone@example.test",
              "apiUrl": "https://fake.test/jmap/api",
              "downloadUrl": "https://fake.test/jmap/download/{accountId}/{blobId}/{name}",
              "uploadUrl": "https://fake.test/jmap/upload/{accountId}",
              "eventSourceUrl": "https://fake.test/jmap/eventsource",
              "state": "1"
            }
            """.utf8)

        return try JSONDecoder().decode(Session.self, from: json)
    }

    private func identity(_ email: String) -> Identity {
        var identity = Identity(id: IdentityID(rawValue: "id-1"))
        identity.email = email

        return identity
    }

    @Test("A nameless account takes its own address")
    func namelessAccountUsesItsAddress() async throws {
        let store = makeStore()

        let accounts = try await store.syncAccounts(
            session: try session(accountName: ""), serverID: "srv")
        let key = try #require(accounts.first?.accountKey)

        // Before identities arrive there is genuinely nothing better to show.
        #expect(try await store.accounts().first?.displayName == "Mailbox 1119")

        try await store.replaceIdentities([identity("work@example.test")], accountKey: key)

        #expect(try await store.accounts().first?.displayName == "work@example.test")
    }

    /// The backfill must not overwrite a name the server actually gave.
    @Test("A named account keeps its name")
    func namedAccountIsUntouched() async throws {
        let store = makeStore()

        let accounts = try await store.syncAccounts(
            session: try session(accountName: "Work"), serverID: "srv")
        let key = try #require(accounts.first?.accountKey)

        try await store.replaceIdentities([identity("work@example.test")], accountKey: key)

        #expect(try await store.accounts().first?.displayName == "Work")
    }

    /// The half of the fix that is easy to miss. Account sync runs on every
    /// launch and every reconnect; if it wrote the server's empty name over
    /// the backfilled address, the label would revert to `Mailbox 1119` a
    /// second after it was fixed, and only sometimes — whichever of the two
    /// syncs happened to run last.
    @Test("A later sync does not overwrite the backfilled address")
    func resyncKeepsTheBackfilledName() async throws {
        let store = makeStore()

        let accounts = try await store.syncAccounts(
            session: try session(accountName: ""), serverID: "srv")
        let key = try #require(accounts.first?.accountKey)

        try await store.replaceIdentities([identity("work@example.test")], accountKey: key)
        try await store.syncAccounts(session: try session(accountName: ""), serverID: "srv")

        #expect(try await store.accounts().first?.displayName == "work@example.test")
    }

    /// A server can return an identity with an empty address — the second
    /// account on my own test server does exactly that. Storing it would put
    /// an empty name on the account, which falls back to the id anyway but
    /// hides the fact that nothing was found.
    @Test("A blank identity address is not used as a name")
    func blankIdentityIsIgnored() async throws {
        let store = makeStore()

        let accounts = try await store.syncAccounts(
            session: try session(accountName: ""), serverID: "srv")
        let key = try #require(accounts.first?.accountKey)

        try await store.replaceIdentities([identity(""), identity("  ")], accountKey: key)

        #expect(try await store.accounts().first?.displayName == "Mailbox 1119")
    }

    /// The composer's From line.
    @Test(
        "An identity reads well however incomplete it is",
        arguments: [
            ("Ada", "ada@example.test", "Ada <ada@example.test>"),
            (nil, "ada@example.test", "ada@example.test"),
            // No address: "Personal <>" looks like a formatting bug.
            ("Personal", "", "Personal"),
            // Name and address identical, which some imports produce.
            ("Work", "Work", "Work"),
        ])
    func identityDisplayName(name: String?, email: String, expected: String) {
        let snapshot = IdentitySnapshot(
            id: IdentityID(rawValue: "1"), name: name, email: email, textSignature: nil)

        #expect(snapshot.displayName == expected)
    }
}
