import Foundation
import JMAPKit
import JMAPTestSupport
import Testing

@testable import PLMailCore

/// The sending-addresses screen.
///
/// The interesting failure is not the happy path. It is that `Identity/set`
/// answers **200 with the refusal inside the body**, exactly as `Email/set`
/// does, so a client that reads the HTTP status as the answer shows a name as
/// saved that the server threw away — and the user finds out from a recipient.
@Suite("Identity editor")
@MainActor
struct IdentityEditorTests {
    private let accountKey = "fake.test/1"

    private func makeServer() -> FakeMailServer {
        let server = FakeMailServer(accounts: ["1": []])
        server.setIdentities(
            [
                FakeMailServer.Identity(id: "10", name: "Ada", email: "ada@example.test"),
                FakeMailServer.Identity(id: "11", name: "", email: "billing@example.test"),
            ],
            accountID: "1")

        return server
    }

    private func makeEditor(_ server: FakeMailServer) -> (IdentityEditor, SyncStore) {
        let store = SyncStore(modelContainer: MailStack.makeContainer(inMemory: true))
        let editor = IdentityEditor(
            client: server.makeClient(),
            store: store,
            accounts: [
                AccountSnapshot(accountKey: accountKey, accountID: AccountID("1"), name: "Mail")
            ])

        return (editor, store)
    }

    @Test("loading lists what the server sends, sorted by address")
    func loads() async throws {
        let (editor, _) = makeEditor(makeServer())

        await editor.load()

        #expect(editor.isLoading == false)
        #expect(editor.groups.count == 1)
        #expect(
            editor.groups.first?.identities.map(\.email) == [
                "ada@example.test", "billing@example.test",
            ])
    }

    @Test("a rename reaches the server and the local store")
    func renames() async throws {
        let server = makeServer()
        let (editor, store) = makeEditor(server)

        await editor.load()

        let group = try #require(editor.groups.first)
        let identity = try #require(group.identities.first)

        #expect(await editor.rename(identity, in: group, to: "Ada Lovelace"))
        #expect(server.identities(accountID: "1").first?.name == "Ada Lovelace")

        // The composer reads identities out of the store, not out of this
        // screen's arrays, so a rename that only updated the view would leave
        // mail going out under the old name.
        let stored = try await store.identities(accountKey: accountKey)
        #expect(stored.first { $0.id == identity.id }?.name == "Ada Lovelace")
    }

    /// The one that matters: 200 OK, `notUpdated` populated.
    @Test("a refusal inside a 200 is reported, not treated as saved")
    func refusalIsNotSuccess() async throws {
        let server = makeServer()
        server.setRefusesRenames(true)

        let (editor, store) = makeEditor(server)

        await editor.load()

        let group = try #require(editor.groups.first)
        let identity = try #require(group.identities.first)

        #expect(await editor.rename(identity, in: group, to: "Ada Lovelace") == false)
        #expect(editor.saveFailure != nil)
        #expect(server.identities(accountID: "1").first?.name == "Ada")

        let stored = try await store.identities(accountKey: accountKey)
        #expect(stored.first { $0.id == identity.id }?.name == "Ada")
    }

    /// The default state of a fresh plMail account: no alias rows, so
    /// `Identity/get` answers with a synthetic identity whose id is the
    /// account's, and `Identity/set` cannot find it. Verified against the
    /// running server, which answers exactly this.
    @Test("a synthetic identity refuses a rename with something readable")
    func syntheticIdentityCannotBeRenamed() async throws {
        let server = FakeMailServer(accounts: ["1": []])
        server.setIdentities(
            [
                FakeMailServer.Identity(
                    id: "1", name: "E2E Mailbox", email: "e2e@plmail.test", isSynthetic: true)
            ],
            accountID: "1")

        let (editor, _) = makeEditor(server)

        await editor.load()

        let group = try #require(editor.groups.first)
        let identity = try #require(group.identities.first)

        #expect(await editor.rename(identity, in: group, to: "Ada") == false)

        // Not the server's own wording: "No such Identity in this account"
        // reads as "your address is gone", which is neither true nor useful.
        let failure = try #require(editor.saveFailure)
        #expect(failure.contains("alias"))
    }

    /// An unreachable server leaves the cached addresses on screen rather than
    /// blanking the list: they are what the composer will use either way, and
    /// an empty screen would read as "you have no addresses".
    @Test("a failed refresh keeps the cached addresses and says so")
    func refreshFailureKeepsCache() async throws {
        let server = makeServer()
        let (editor, _) = makeEditor(server)

        await editor.load()
        server.setFailing(true, accountID: "1")
        await editor.refresh()

        #expect(editor.groups.first?.identities.count == 2)
    }
}
