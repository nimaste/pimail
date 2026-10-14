import Foundation
import JMAPKit
import Testing

@testable import PLMailCore

/// A JMAP account name is optional, and a real plMail server was found
/// serving an empty one. The app rendered a blank row in the sign-in
/// confirmation list and an empty grey pill on every message from that
/// account — which looks like a rendering bug and conveys nothing.
@Suite("Account display name")
struct AccountDisplayNameTests {
    private func account(named name: String) -> AccountSnapshot {
        AccountSnapshot(accountKey: "srv/1119", accountID: AccountID("1119"), name: name)
    }

    @Test("A named account keeps its name")
    func named() {
        #expect(account(named: "E2E Mailbox").displayName == "E2E Mailbox")
    }

    @Test(
        "An unnamed account falls back to something identifying",
        arguments: ["", " ", "\n", "  \t "])
    func blank(name: String) {
        #expect(account(named: name).displayName == "Mailbox 1119")
    }

    /// Two nameless accounts must not read as the same mailbox — the whole
    /// point of the row is telling them apart.
    @Test("Two unnamed accounts get different labels")
    func distinct() {
        let first = AccountSnapshot(
            accountKey: "srv/71", accountID: AccountID("71"), name: "")
        let second = AccountSnapshot(
            accountKey: "srv/1119", accountID: AccountID("1119"), name: "")

        #expect(first.displayName != second.displayName)
    }

    @Test("Surrounding whitespace is trimmed rather than rendered")
    func trimmed() {
        #expect(account(named: "  Work  ").displayName == "Work")
    }
}
