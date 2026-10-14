import Foundation
import JMAPKit
import JMAPTestSupport
import Testing

@testable import PLMailCore

/// Two accounts, so the composer has a choice to get right.
private enum OrderFixtures {
    static let sessionJSON = """
        {
          "capabilities": {
            "urn:ietf:params:jmap:core": {
              "maxSizeUpload": 50000000,
              "maxConcurrentUpload": 4,
              "maxSizeRequestObject": 10000000,
              "maxConcurrentRequests": 4,
              "maxCallsInRequest": 32,
              "maxObjectsInGet": 500,
              "maxObjectsInSet": 500,
              "collationAlgorithms": ["i;unicode-casemap"]
            }
          },
          "accounts": {
            "1": { "name": "work@example.org", "isPersonal": true, "isReadOnly": false,
                   "accountCapabilities": { "urn:ietf:params:jmap:mail": {} } },
            "2": { "name": "home@example.org", "isPersonal": true, "isReadOnly": false,
                   "accountCapabilities": { "urn:ietf:params:jmap:mail": {} } }
          },
          "primaryAccounts": { "urn:ietf:params:jmap:mail": "1" },
          "username": "me@example.org",
          "apiUrl": "https://nas.local/jmap/api",
          "downloadUrl": "https://nas.local/jmap/download/{accountId}/{blobId}/{name}",
          "uploadUrl": "https://nas.local/jmap/upload/{accountId}",
          "eventSourceUrl": "https://nas.local/jmap/eventsource",
          "state": "s0"
        }
        """

    /// Answers `Identity/get` with nothing, so the refresh cannot decide the
    /// question this test is asking. The identities under test are already in
    /// the store.
    static let emptyIdentityJSON = """
        {"methodResponses": [["Identity/get", {"accountId": "1", "state": "s1",
        "list": [], "notFound": []}, "c0"]]}
        """
}

/// No address book, so a compose test never waits on permission.
private struct SilentContacts: ContactSource {
    func addresses(matching fragment: String) async -> [EmailAddress] { [] }
}

/// Which address a new message goes out as, when the composer was not told.
///
/// ``AccountOrder`` is what the accounts screen writes when somebody drags a
/// mailbox to the top, and its own documentation has always claimed it decides
/// this. It did not: the composer took whichever account the store handed back
/// first, so ordering was cosmetic and a work reply could open as a personal
/// address for no reason visible on screen.
@Suite("Compose account order")
@MainActor
struct ComposeAccountOrderTests {
    private func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "de.plmail.tests.\(UUID().uuidString)"))
    }

    private func identity(_ id: String, _ email: String) -> Identity {
        var identity = Identity(id: IdentityID(id))
        identity.email = email
        identity.name = email

        return identity
    }

    /// A store holding both accounts and one sendable address each.
    private func seededStore() async throws -> SyncStore {
        let store = SyncStore(modelContainer: MailStack.makeContainer(inMemory: true))
        let session = try JSONDecoder().decode(
            Session.self, from: Data(OrderFixtures.sessionJSON.utf8))

        try await store.syncAccounts(session: session, serverID: "nas.local")
        try await store.replaceIdentities(
            [identity("i1", "work@example.org")], accountKey: "nas.local/1")
        try await store.replaceIdentities(
            [identity("i2", "home@example.org")], accountKey: "nas.local/2")

        return store
    }

    private func model(store: SyncStore, order: AccountOrder) -> ComposeModel {
        let transport = MockTransport { request in
            let isDiscovery = request.url?.path().contains(".well-known") == true
            let body =
                isDiscovery ? OrderFixtures.sessionJSON : OrderFixtures.emptyIdentityJSON

            return (Data(body.utf8), MockTransport.response(for: request))
        }

        // Deliberately an account key the store does not know. That is the
        // composer opened without a mailbox of its own to fall back on — the
        // unified inbox, a `mailto:` from another app — which is exactly the
        // case the user's ordering is supposed to answer.
        return ComposeModel(
            kind: .new,
            accountKey: "nas.local/unknown",
            accountID: AccountID("1"),
            client: JMAPClient(
                discoveryURL: URL(string: "https://nas.local/.well-known/jmap")!,
                credential: .appPassword("plmail_test"),
                transport: transport),
            store: store,
            outbox: Outbox(serverID: "test-\(UUID().uuidString)"),
            contacts: SilentContacts(),
            order: order
        )
    }

    /// **`work@` is the harder assertion of the two.** The store hands
    /// accounts back in `Session.orderedAccounts` order, which is alphabetical
    /// by name, so `home@example.org` is what a composer that ignores the
    /// user's ordering picks. Asserting on `work@` therefore fails on the old
    /// behaviour rather than agreeing with it by accident.
    @Test("The account the user dragged to the top is what a new message goes out as")
    func theFirstOrderedAccountWins() async throws {
        let defaults = try defaults()
        AccountOrder(defaults: defaults).setOrder(["nas.local/1", "nas.local/2"])

        let model = self.model(
            store: try await seededStore(), order: AccountOrder(defaults: defaults))

        await model.load()

        #expect(model.selectedIdentity?.accountKey == "nas.local/1")
        #expect(model.selectedIdentity?.address.email == "work@example.org")
    }

    /// The control: nothing is imposed on somebody who has never reordered
    /// anything. An empty stored order has to leave the accounts exactly as
    /// they arrived, which here is the session's alphabetical order.
    @Test("With no stored order the server's own order stands")
    func anUntouchedOrderChangesNothing() async throws {
        let model = self.model(
            store: try await seededStore(), order: AccountOrder(defaults: try defaults()))

        await model.load()

        #expect(model.selectedIdentity?.accountKey == "nas.local/2")
    }

    /// The From picker reads in the same order, so the list somebody scrolls
    /// matches the list they arranged.
    @Test("The From picker is in the user's order too")
    func thePickerFollows() async throws {
        let defaults = try defaults()
        AccountOrder(defaults: defaults).setOrder(["nas.local/1", "nas.local/2"])

        let model = self.model(
            store: try await seededStore(), order: AccountOrder(defaults: defaults))

        await model.load()

        #expect(model.identities.map(\.accountKey) == ["nas.local/1", "nas.local/2"])
    }
}
