import Foundation
import JMAPKit
import JMAPTestSupport
import Testing

@testable import PLMailCore

/// The one question this app asks about sending anything anywhere.
///
/// Recipient suggestions have always been computed on the device — from mail
/// already synced, and from the system address book — and the contacts
/// permission string says so. Asking the server ranks them far better and sends
/// a prefix of what is being typed to it. **The default is to ask, not to
/// assume**, and these tests are what stops a refactor turning "undecided" into
/// a silent yes.
@Suite("Recipient privacy")
struct RecipientPrivacyTests {
    /// Its own defaults suite per test, so one run cannot answer the privacy
    /// question for the next.
    private func preference() throws -> ServerSuggestionPreference {
        let name = "privacy-\(UUID().uuidString)"

        return ServerSuggestionPreference(defaults: try #require(UserDefaults(suiteName: name)))
    }

    @Test("A fresh install has not been asked, and that is not a yes")
    func defaultIsUndecided() throws {
        let preference = try preference()

        #expect(preference.consent == .undecided)
        #expect(preference.consent.permitsLookup == false)
    }

    @Test("Only an explicit yes lets a lookup leave the device")
    func onlyYesPermits() {
        #expect(ServerSuggestionConsent.allowed.permitsLookup)
        #expect(ServerSuggestionConsent.declined.permitsLookup == false)
        #expect(ServerSuggestionConsent.undecided.permitsLookup == false)
    }

    /// **Nothing on the wire before an answer.** The transport is the whole
    /// assertion: a request recorded here is a keystroke that left the phone
    /// without being agreed to.
    @Test("Nothing is sent to the server until somebody has said yes")
    func undecidedSendsNothing() async throws {
        let transport = MockTransport(body: Data("{}".utf8), statusCode: 500)
        let contacts = ServerContacts(
            client: JMAPClient(
                discoveryURL: URL(string: "https://nas.local/.well-known/jmap")!,
                credential: .appPassword("plmail_test"),
                transport: transport),
            accountID: AccountID("1"),
            preference: try preference())

        #expect(await contacts.addresses(matching: "ada").isEmpty)
        #expect(transport.requestCount == 0, "not even a session fetch")
    }

    @Test("Declining is remembered, and keeps sending nothing")
    func decliningIsRemembered() async throws {
        let preference = try preference()
        let transport = MockTransport(body: Data("{}".utf8), statusCode: 500)
        let contacts = ServerContacts(
            client: JMAPClient(
                discoveryURL: URL(string: "https://nas.local/.well-known/jmap")!,
                credential: .appPassword("plmail_test"),
                transport: transport),
            accountID: AccountID("1"),
            preference: preference)

        preference.consent = .declined

        #expect(preference.consent == .declined)
        #expect(await contacts.addresses(matching: "ada").isEmpty)
        #expect(transport.requestCount == 0)
    }

    /// One letter matches most of an address book, so the round trip buys
    /// nothing and the keystroke is disclosed for no result.
    @Test("A single character is never worth disclosing")
    func oneCharacterIsNotSent() async throws {
        let preference = try preference()

        preference.consent = .allowed

        let transport = MockTransport(body: Data("{}".utf8), statusCode: 500)
        let contacts = ServerContacts(
            client: JMAPClient(
                discoveryURL: URL(string: "https://nas.local/.well-known/jmap")!,
                credential: .appPassword("plmail_test"),
                transport: transport),
            accountID: AccountID("1"),
            preference: preference)

        #expect(await contacts.addresses(matching: "a").isEmpty)
        #expect(transport.requestCount == 0)
    }

    /// The server's ranking stays on top, and the address book supplements it
    /// with people the user has never mailed — which is exactly what the server
    /// cannot know. Merged by lowercased address, first source wins.
    @Test("Server suggestions rank above the address book, deduplicated by address")
    func serverRanksFirst() async {
        let combined = CombinedContacts([
            StubContacts([
                EmailAddress(name: "Ada Lovelace", email: "ada@example.org"),
                EmailAddress(name: "Bob", email: "bob@example.org"),
            ]),
            StubContacts([
                // The same person, spelled differently and known less well.
                EmailAddress(name: "A. Lovelace", email: "ADA@example.org"),
                EmailAddress(name: "Grace", email: "grace@example.org"),
            ]),
        ])

        let found = await combined.addresses(matching: "a")

        #expect(found.map(\.email) == ["ada@example.org", "bob@example.org", "grace@example.org"])
        #expect(found.first?.name == "Ada Lovelace", "the server's spelling wins")
    }

    /// A source that fails answers nothing, and the other one still answers —
    /// which is what makes a phone in a lift still suggest.
    @Test("One source failing does not silence the other")
    func oneSourceFailing() async {
        let combined = CombinedContacts([
            StubContacts([]),
            StubContacts([EmailAddress(email: "grace@example.org")]),
        ])

        #expect(await combined.addresses(matching: "gra").map(\.email) == ["grace@example.org"])
    }
}

/// Answers a fixed list, so the merge can be tested without a server or a
/// permission prompt.
private struct StubContacts: ContactSource {
    private let list: [EmailAddress]

    init(_ list: [EmailAddress]) {
        self.list = list
    }

    func addresses(matching fragment: String) async -> [EmailAddress] { list }
}
