import CoreSpotlight
import Foundation
public import JMAPKit
import OSLog

/// Puts events that are **already cached** into system search.
///
/// The same two rules as `MailSpotlightIndex`, and they matter more here:
///
/// - **It is never a reason to sync.** Everything read comes out of the local
///   store. The calendar has no `/changes`, no push and no delta —
///   `queryState` is the literal string `"fixed"` — so an index that fetched
///   would have to re-run whole windowed queries against a Raspberry Pi with
///   one PHP worker pool merely because somebody searched their Mac for a word.
/// - **It is never a full re-scan.** A high-water record of what has been
///   indexed, and of the *signature* it was indexed at, means an unchanged
///   month costs one local fetch and zero writes.
///
/// Deletion is the correctness requirement rather than a nicety. A cancelled
/// meeting left in Spotlight is a person turning up to it; an entry left behind
/// after sign-out leaks the previous account's calendar to whoever holds the
/// device next. Both are handled — the first by the reconciliation pass in
/// ``refresh(accountKey:)``, the second by ``removeEverything()``.
///
/// Its planners are deliberately `static` and pure so a test target can pick
/// them up without CoreSpotlight, a store or a device.
public actor CalendarSpotlightIndex {
    private static let logger = Logger(subsystem: "de.plmail", category: "spotlight")

    /// A domain of its own, separate from the mail one, so that clearing
    /// calendar entries cannot take conversations with it and vice versa.
    public static let domain = "de.plmail.events"

    /// How many events one pass will describe.
    ///
    /// A cap rather than "everything new": the first pass after a year view has
    /// been opened has hundreds of occurrences to write, and doing that on the
    /// tail of a sync is how a foreground refresh becomes visibly slow. What is
    /// missed is picked up next time, and an event not yet in system search is
    /// a far smaller failure than a calendar that stutters when it opens.
    public static let batchLimit = 200

    /// Where the high-water record lives.
    ///
    /// `UserDefaults` rather than the store, deliberately: the store is a cache
    /// that any open failure deletes and rebuilds, and a record that vanished
    /// with it would turn every such recovery into a full re-index. Losing it
    /// costs one extra pass and nothing else, so it has no business in the
    /// Keychain either.
    private static let recordKey = "plmail.spotlight.events"

    private let store: CalendarStore
    private let defaults: UserDefaults
    private let index: CSSearchableIndex

    /// Occurrence id → the signature it was last indexed at.
    private var indexed: [String: String]

    public init(
        store: CalendarStore,
        defaults: UserDefaults = .standard,
        index: CSSearchableIndex = .default()
    ) {
        self.store = store
        self.defaults = defaults
        self.index = index
        indexed = defaults.dictionary(forKey: Self.recordKey) as? [String: String] ?? [:]
    }

    // MARK: - One pass

    /// Brings the index up to date with what the cache holds.
    ///
    /// Safe after any refresh and harmless when nothing changed. **Never call
    /// it on a timer**: it is a consequence of a window having been re-queried,
    /// not a way of finding out whether it should be.
    public func refresh(accountKey: String) async {
        let rows: [CalendarOccurrenceSnapshot]

        do {
            rows = try await store.allOccurrences(accountKey: accountKey)
        } catch {
            Self.logger.error("Could not read events to index: \(error, privacy: .public)")

            return
        }

        await removeVanished(keeping: rows)
        await add(Self.pending(in: rows, alreadyIndexed: indexed).prefix(Self.batchLimit))
    }

    /// What still needs describing: occurrences never indexed, and occurrences
    /// whose signature has moved on since they were.
    ///
    /// Static and pure, so the incrementality — the property that stops this
    /// being a re-scan — is testable without CoreSpotlight or a device.
    public static func pending(
        in rows: [CalendarOccurrenceSnapshot], alreadyIndexed: [String: String]
    ) -> [CalendarOccurrenceSnapshot] {
        rows.filter { alreadyIndexed[uid(for: $0)] != signature(of: $0) }
    }

    /// Everything indexed that the cache no longer holds.
    ///
    /// A window re-queried after an event was deleted on the server drops the
    /// row, and this is what takes it out of system search with it.
    public static func vanished(
        from rows: [CalendarOccurrenceSnapshot], alreadyIndexed: [String: String]
    ) -> [String] {
        let live = Set(rows.map(uid(for:)))

        return alreadyIndexed.keys.filter { live.contains($0) == false }
    }

    /// What has to differ before an entry is worth rewriting.
    ///
    /// Title, wall clock and status, because those are exactly the three things
    /// a search result shows — and status is in it because a **cancelled**
    /// occurrence that kept its old entry is the failure mode that sends
    /// somebody to a meeting that is not happening.
    public static func signature(of row: CalendarOccurrenceSnapshot) -> String {
        [row.title, row.startLocal, row.status ?? ""].joined(separator: "|")
    }

    /// The identifier a Spotlight result carries back when it is tapped.
    ///
    /// The same shape as `StoreKey.object(accountKey:id:)`, and read back by
    /// splitting on the **last** `#`: an account key is `server/account` and
    /// neither half is guaranteed free of what a naive split would choke on.
    public static func uid(for row: CalendarOccurrenceSnapshot) -> String {
        "\(row.accountKey)#\(row.occurrenceID.rawValue)"
    }

    /// The account key and occurrence id behind a Spotlight identifier, or nil
    /// if it is not one of ours.
    public static func ids(forUID uid: String) -> (accountKey: String, occurrenceID: String)? {
        guard let separator = uid.range(of: "#", options: .backwards) else { return nil }

        let accountKey = String(uid[uid.startIndex..<separator.lowerBound])
        let occurrenceID = String(uid[separator.upperBound...])

        guard accountKey.isEmpty == false, occurrenceID.isEmpty == false else { return nil }

        return (accountKey, occurrenceID)
    }

    /// Whether this index is the one that wrote `uid`.
    ///
    /// **The shell cannot tell an event from a conversation by looking.**
    /// `MailSpotlightIndex.uid(for:)` and ``uid(for:)`` are both
    /// `accountKey#id`, deliberately, and a tapped result hands back only the
    /// identifier — the domain that separates them is not in the activity. So
    /// `RootView` asks the index that would have written it. Without this the
    /// mail branch claims every event tap and opens a conversation that does
    /// not exist, which is the dead end indexing events created in the first
    /// place.
    ///
    /// The record can be lost — it lives in `UserDefaults` on purpose — so a
    /// false answer here is not proof it is not ours; the caller falls back to
    /// resolving the id against the cache.
    public func knows(_ uid: String) -> Bool {
        Self.isIndexed(uid, in: indexed)
    }

    /// The same question against a record handed in, so the ownership rule is
    /// testable without CoreSpotlight, a store or a `UserDefaults` suite.
    ///
    /// **A false answer is not proof it is not ours.** The record is
    /// deliberately losable — it lives in `UserDefaults` so that dropping the
    /// cache does not force a full re-index — so the caller resolves the id
    /// against the cache before giving up on it.
    public static func isIndexed(_ uid: String, in record: [String: String]) -> Bool {
        record[uid] != nil
    }

    // MARK: - Writing

    private func add(_ rows: some Collection<CalendarOccurrenceSnapshot>) async {
        guard rows.isEmpty == false else { return }

        var items: [CSSearchableItem] = []
        var signatures: [String: String] = [:]

        for row in rows {
            let attributes = CSSearchableItemAttributeSet(contentType: .content)
            attributes.title = row.title
            // The wall clock as text rather than as `startDate`. Spotlight would
            // render a `Date` in the device's zone, and an event in another zone
            // is drawn against the clock its own zone names everywhere else in
            // this app — a search result an hour out from the calendar row it
            // came from is worse than one that does not sort by time.
            attributes.contentDescription = row.startLocal.replacingOccurrences(
                of: "T", with: " ")

            items.append(
                CSSearchableItem(
                    uniqueIdentifier: Self.uid(for: row),
                    domainIdentifier: Self.domain,
                    attributeSet: attributes))

            signatures[Self.uid(for: row)] = Self.signature(of: row)
        }

        do {
            try await index.indexSearchableItems(items)
            indexed.merge(signatures) { _, new in new }
            writeRecord()
        } catch {
            // Nothing is recorded on failure, so the next pass tries the same
            // rows again. Recording optimistically would leave events
            // permanently absent from search with no way to notice.
            Self.logger.error("Could not index \(items.count) events: \(error, privacy: .public)")
        }
    }

    private func removeVanished(keeping rows: [CalendarOccurrenceSnapshot]) async {
        let gone = Self.vanished(from: rows, alreadyIndexed: indexed)

        guard gone.isEmpty == false else { return }

        do {
            try await index.deleteSearchableItems(withIdentifiers: gone)

            for uid in gone { indexed.removeValue(forKey: uid) }

            writeRecord()
        } catch {
            Self.logger.error("Could not remove \(gone.count) events: \(error, privacy: .public)")
        }
    }

    /// Everything, on sign-out.
    ///
    /// By domain rather than by id: sign-out deletes the cache in the same
    /// breath, so by the time anyone thought to enumerate the ids there would
    /// be nothing left to enumerate them from.
    public func removeEverything() async {
        indexed = [:]
        writeRecord()

        do {
            try await index.deleteSearchableItems(withDomainIdentifiers: [Self.domain])
        } catch {
            Self.logger.error("Could not clear the event index: \(error, privacy: .public)")
        }
    }

    private func writeRecord() {
        defaults.set(indexed, forKey: Self.recordKey)
    }
}
