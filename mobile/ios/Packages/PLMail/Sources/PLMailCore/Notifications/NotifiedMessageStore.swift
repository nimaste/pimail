import Foundation

/// Which messages have already been announced.
///
/// **Without this, one background wake after a long absence posts a hundred
/// banners.** "New" to a delta pull means "the server changed it", which is
/// true of a re-indexed message, of a cursor that expired and forced a
/// re-page, and of every message in the cache after a store rebuild. None of
/// those is news to the person holding the phone.
///
/// An `actor`, because two syncs can overlap — a silent push and the periodic
/// refresh routinely land together — and both would otherwise read the same
/// empty set and announce the same message twice. ``claim(_:)`` is the whole
/// point: it reads, filters and writes without an await in between, so exactly
/// one of two concurrent callers is told a message is new.
///
/// `UserDefaults` rather than the SwiftData store, deliberately: the store is
/// a cache that may be deleted whole on any open failure, and a dedupe record
/// that vanishes with it would announce the entire mailbox on the next pull.
public actor NotifiedMessageStore {
    /// How many identifiers are remembered.
    ///
    /// Two thousand is a few weeks of a busy mailbox and roughly 60 kB of
    /// strings. The bound exists because the alternative is a list that grows
    /// for the life of the install; the cost of being wrong at this size is
    /// one duplicate banner for a message from a month ago, which is far
    /// cheaper than the unbounded version.
    public static let capacity = 2000

    private enum Key {
        static let announced = "de.plmail.notify.announced"
        static let primedAccounts = "de.plmail.notify.primedAccounts"
    }

    /// `UserDefaults` is thread-safe and documented as such; the annotation is
    /// only because it predates `Sendable`.
    private nonisolated(unsafe) let defaults: UserDefaults

    private let capacity: Int

    /// Insertion-ordered, oldest first, so trimming drops the mail nobody is
    /// going to be re-notified about anyway. A `Set` would be a faster lookup
    /// and would give no way to decide what to forget.
    private var announced: [String]
    private var announcedIndex: Set<String>
    private var primedAccounts: Set<String>

    /// - Parameters:
    ///   - suiteName: Nil for the app's own defaults. Named only by tests,
    ///     which need an isolated store: a dedupe test that passes only when it
    ///     runs first is worse than no dedupe test. A **name** rather than a
    ///     `UserDefaults` because that type is not `Sendable`, and handing one
    ///     across an actor boundary is a compile error under strict
    ///     concurrency — the object is thread-safe, but the compiler has no way
    ///     to know it.
    ///   - capacity: How many identifiers to remember. See ``capacity``.
    public init(suiteName: String? = nil, capacity: Int = capacity) {
        defaults = suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
        self.capacity = capacity

        announced = defaults.stringArray(forKey: Key.announced) ?? []
        announcedIndex = Set(announced)
        primedAccounts = Set(defaults.stringArray(forKey: Key.primedAccounts) ?? [])
    }

    /// Whether this account has ever had a notification pass run against it.
    ///
    /// False on the very first pass — a fresh sign-in, or the upgrade that
    /// introduced notifications to an install that already has a month of
    /// cached mail. Everything in the mailbox is "unannounced" at that moment
    /// and none of it is news, so the first pass claims silently. Recording it
    /// per account rather than per app matters on a server aggregating five
    /// IMAP accounts, where the fifth is connected weeks after the first.
    public func isPrimed(accountKey: String) -> Bool {
        primedAccounts.contains(accountKey)
    }

    public func markPrimed(accountKey: String) {
        guard primedAccounts.contains(accountKey) == false else { return }

        primedAccounts.insert(accountKey)
        defaults.set(Array(primedAccounts).sorted(), forKey: Key.primedAccounts)
    }

    /// Takes ownership of the identifiers that have not been announced before.
    ///
    /// - Returns: The subset this caller may announce, in the order given.
    ///   Everything returned is recorded as announced **before** this method
    ///   returns, so a caller that then crashes has lost a banner rather than
    ///   gained a duplicate. Losing a banner is recoverable — the mail is
    ///   still unread and still in the list; a duplicate is not.
    @discardableResult
    public func claim(_ identifiers: [String]) -> [String] {
        var claimed: [String] = []

        for identifier in identifiers where announcedIndex.contains(identifier) == false {
            announcedIndex.insert(identifier)
            announced.append(identifier)
            claimed.append(identifier)
        }

        guard claimed.isEmpty == false else { return [] }

        if announced.count > capacity {
            let dropped = announced.prefix(announced.count - capacity)

            announcedIndex.subtract(dropped)
            announced.removeFirst(announced.count - capacity)
        }

        defaults.set(announced, forKey: Key.announced)

        return claimed
    }

    /// Whether an identifier has been announced. Reading only — a caller that
    /// intends to announce must use ``claim(_:)``, or two of them will both
    /// see "not yet" and both post.
    public func hasAnnounced(_ identifier: String) -> Bool {
        announcedIndex.contains(identifier)
    }

    /// Forgets everything, for a sign-out.
    ///
    /// The next account signed in on this device is a different mailbox, and
    /// carrying the previous one's identifiers forward would silence its mail
    /// wherever the two servers happen to have issued the same message id —
    /// which they will, because ids are only unique within an account.
    public func reset() {
        announced = []
        announcedIndex = []
        primedAccounts = []

        defaults.removeObject(forKey: Key.announced)
        defaults.removeObject(forKey: Key.primedAccounts)
    }
}
