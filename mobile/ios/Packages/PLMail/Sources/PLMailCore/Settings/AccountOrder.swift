import Foundation
import Observation

/// The order the user put their mailboxes in.
///
/// **Not cosmetic.** The first account decides which address the composer opens
/// on and where a new label is created, so someone with a work and a personal
/// mailbox is ordering the one their mail goes out as by default.
///
/// `UserDefaults` rather than the store, for the reason the store's own banner
/// gives: `SchemaV1` is a cache that any open failure deletes and re-syncs, and
/// nothing on the server can reconstruct a user's ordering. Keeping it on
/// `StoredAccount` would quietly reset it on the next schema change, which
/// looks like the app forgetting a setting rather than a cache being rebuilt.
@MainActor
@Observable
public final class AccountOrder {
    /// One instance, written by the accounts screen and read wherever an
    /// account list is drawn — the same argument `AppearancePreference` makes.
    public static let shared = AccountOrder()

    /// Namespaced and defined once. Two spellings of one key in two files is a
    /// preference that saves and never loads, and nothing at the call site
    /// looks wrong.
    private enum Key {
        static let order = "de.plmail.accounts.order"
    }

    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults

    /// Account keys, in the order the user chose. **Not necessarily the
    /// accounts that exist**: a mailbox disconnected on the server leaves its
    /// key here, and one connected since is missing from it. ``ordered(_:)`` is
    /// what reconciles the two, and callers should use it rather than this.
    public private(set) var keys: [String]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        keys = defaults.stringArray(forKey: Key.order) ?? []
    }

    /// Accounts in the user's order.
    ///
    /// Accounts the stored order does not mention go **after** the ones it
    /// does, keeping their own relative order. A newly connected mailbox
    /// therefore appears at the bottom rather than jumping to the top and
    /// silently becoming the composer's default — which is a change to where
    /// somebody's mail goes out from, made by a server-side action they took
    /// for an unrelated reason.
    public func ordered<Account>(
        _ accounts: [Account], key: (Account) -> String
    ) -> [Account] {
        var rank: [String: Int] = [:]

        for (index, stored) in keys.enumerated() { rank[stored] = index }

        return accounts.enumerated()
            .sorted { left, right in
                let leftRank = rank[key(left.element)] ?? Int.max
                let rightRank = rank[key(right.element)] ?? Int.max

                // The original index breaks the tie so the sort is stable
                // across two unranked accounts, which `sorted(by:)` does not
                // promise on its own.
                if leftRank == rightRank { return left.offset < right.offset }

                return leftRank < rightRank
            }
            .map(\.element)
    }

    /// Records a new order.
    ///
    /// The keys written are exactly the ones passed, so an account that has
    /// disappeared from the session drops out of the stored order the first
    /// time the screen is reordered rather than accumulating forever.
    public func setOrder(_ orderedKeys: [String]) {
        keys = orderedKeys
        defaults.set(orderedKeys, forKey: Key.order)
    }
}
