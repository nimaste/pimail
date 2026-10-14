import Foundation
import Testing

@testable import PLMailCore

/// The order the user put their mailboxes in decides which address a new
/// message goes out as, so the ways it can quietly change are the interesting
/// ones.
@Suite("Account order")
@MainActor
struct AccountOrderTests {
    private func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "de.plmail.tests.\(UUID().uuidString)"))
    }

    private struct Account: Equatable {
        var key: String
    }

    private func ordered(_ order: AccountOrder, _ keys: [String]) -> [String] {
        order.ordered(keys.map(Account.init), key: \.key).map(\.key)
    }

    @Test("An untouched order leaves the accounts as they came")
    func untouchedOrderIsTheServersOrder() throws {
        let order = AccountOrder(defaults: try defaults())

        #expect(ordered(order, ["a", "b", "c"]) == ["a", "b", "c"])
    }

    @Test("A saved order survives a relaunch")
    func savedOrderIsRead() throws {
        let defaults = try defaults()

        AccountOrder(defaults: defaults).setOrder(["c", "a", "b"])

        #expect(ordered(AccountOrder(defaults: defaults), ["a", "b", "c"]) == ["c", "a", "b"])
    }

    /// The case that matters: a mailbox connected on the server this morning
    /// must not jump to the top and silently become the composer's default,
    /// which is a change to where somebody's mail goes out from made by an
    /// action they took for an unrelated reason.
    @Test("A newly connected account goes to the bottom, not the top")
    func newAccountsSortLast() throws {
        let defaults = try defaults()

        AccountOrder(defaults: defaults).setOrder(["b", "a"])

        #expect(ordered(AccountOrder(defaults: defaults), ["a", "b", "new"]) == ["b", "a", "new"])
    }

    /// Two accounts the stored order says nothing about must keep their
    /// relative order, which `sorted(by:)` does not promise on its own.
    @Test("Unranked accounts keep their relative order")
    func unrankedAccountsAreStable() throws {
        let defaults = try defaults()

        AccountOrder(defaults: defaults).setOrder(["z"])

        #expect(
            ordered(AccountOrder(defaults: defaults), ["a", "b", "c", "z"])
                == ["z", "a", "b", "c"])
    }

    /// An account disconnected on the server leaves a key behind. It must not
    /// affect anything, and it drops out the next time the screen is reordered.
    @Test("A stored key for an account that no longer exists is harmless")
    func staleKeysAreIgnored() throws {
        let defaults = try defaults()

        AccountOrder(defaults: defaults).setOrder(["gone", "b", "a"])

        #expect(ordered(AccountOrder(defaults: defaults), ["a", "b"]) == ["b", "a"])
    }
}
