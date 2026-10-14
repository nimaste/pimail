import CoreSpotlight
import Foundation
import OSLog
import PLMailCore

/// Puts conversations that are **already cached** into system search.
///
/// Two rules, and the whole design follows from them:
///
/// - **It is never a reason to sync.** Everything here reads the local store.
///   The audience runs the server on a Raspberry Pi with one PHP worker pool,
///   and an index that fetched would turn "search your Mac for a word" into a
///   load on somebody's NAS.
/// - **It is never a full re-scan.** A high-water record of what has already
///   been indexed, and at what date, means an unchanged inbox costs one local
///   fetch and zero writes. Re-indexing the mailbox on every launch is the
///   version of this feature that quietly halves battery life.
///
/// Deletion is the correctness requirement rather than a nicety: an item left
/// behind after the conversation is gone leaks mail metadata into system
/// search, and an item left behind after **sign-out** leaks the previous
/// account's mail to whoever holds the device next. Both are handled — the
/// first by the reconciliation pass in ``refresh(accounts:)``, the second by
/// ``removeEverything()``.
actor MailSpotlightIndex {
    private static let logger = Logger(subsystem: "de.plmail", category: "spotlight")

    /// One domain for everything this app indexes, so sign-out is a single
    /// delete rather than a walk over ids the app may no longer be able to
    /// enumerate — which is exactly the situation after the store has been
    /// dropped.
    static let domain = "de.plmail.threads"

    /// How many conversations one pass will hydrate.
    ///
    /// A cap rather than "everything new", because the first pass after a
    /// fresh sign-in has a whole month of mail to describe, and doing it in one
    /// go on the tail of a `BGAppRefreshTask` is how a background wake gets
    /// killed by the watchdog. What is missed is picked up by the next pass,
    /// and mail that is not in system search yet is a smaller failure than a
    /// background task the system stops granting.
    static let batchLimit = 100

    /// Where the high-water record lives.
    ///
    /// `UserDefaults` rather than the store, deliberately: the store is a cache
    /// that any open failure deletes and re-syncs, and a record that vanished
    /// with it would turn every such recovery into a full re-index. It is also
    /// not irreplaceable — losing it costs one extra pass, nothing more — so it
    /// has no business in the Keychain either.
    private static let recordKey = "plmail.spotlight.indexed"

    /// The feed indexed, and the only one.
    ///
    /// The unified inbox is what "search my mail" means to a person who has
    /// not opened the app. Indexing every paged list as well would put the same
    /// conversation in the index under several rows and multiply the work by
    /// however many lists happen to have been scrolled.
    private static let indexedFeed = FeedID.unified(.inbox)

    private let store: SyncStore
    private let defaults: UserDefaults
    private let index: CSSearchableIndex

    /// Conversation uid → the sort date it was last indexed at. A changed date
    /// is what tells a new reply in an old thread apart from a thread nothing
    /// has happened to.
    private var indexed: [String: Date]

    init(
        store: SyncStore,
        defaults: UserDefaults = .standard,
        index: CSSearchableIndex = .default()
    ) {
        self.store = store
        self.defaults = defaults
        self.index = index
        indexed = Self.readRecord(from: defaults)
    }

    // MARK: - One pass

    /// Brings the index up to date with what the cache holds.
    ///
    /// Safe to call after any sync and harmless when nothing changed. Never
    /// call it on a timer: it is a consequence of new mail having arrived, not
    /// a way of finding out whether it has.
    func refresh() async {
        let rows: [FeedEntrySnapshot]

        do {
            rows = try await store.feedRows(feedID: Self.indexedFeed.rawValue)
        } catch {
            Self.logger.error("Could not read the feed to index: \(error, privacy: .public)")
            return
        }

        await removeVanished(keeping: rows)
        await add(Self.pending(in: rows, alreadyIndexed: indexed).prefix(Self.batchLimit))
    }

    /// What still needs describing: rows never indexed, and rows whose newest
    /// message has moved on since they were.
    ///
    /// Static and pure so the incrementality — the property that stops this
    /// being a re-scan — is testable without CoreSpotlight, a store or a
    /// device.
    static func pending(
        in rows: [FeedEntrySnapshot], alreadyIndexed: [String: Date]
    ) -> [FeedEntrySnapshot] {
        rows.filter { alreadyIndexed[uid(for: $0)] != $0.sortDate }
    }

    /// Everything indexed that the feed no longer contains.
    ///
    /// A conversation archived, trashed or filed elsewhere leaves the inbox
    /// feed, and this is what takes it out of system search with it. Pure for
    /// the same reason as ``pending(in:alreadyIndexed:)``.
    static func vanished(
        from rows: [FeedEntrySnapshot], alreadyIndexed: [String: Date]
    ) -> [String] {
        let live = Set(rows.map(uid(for:)))

        return alreadyIndexed.keys.filter { live.contains($0) == false }
    }

    /// The identifier a Spotlight result carries back when it is tapped.
    ///
    /// The same shape as `StoreKey.object(accountKey:id:)` on purpose, and read
    /// back by splitting on the **last** `#`: an account key is
    /// `server/account` and neither half is guaranteed free of the characters
    /// a naive split would choke on.
    static func uid(for row: FeedEntrySnapshot) -> String {
        "\(row.accountKey)#\(row.threadID)"
    }

    /// The two ids behind a Spotlight identifier, or nil if it is not one of
    /// ours.
    static func ids(forUID uid: String) -> (accountKey: String, threadID: String)? {
        guard let separator = uid.range(of: "#", options: .backwards) else { return nil }

        let accountKey = String(uid[uid.startIndex..<separator.lowerBound])
        let threadID = String(uid[separator.upperBound...])

        guard accountKey.isEmpty == false, threadID.isEmpty == false else { return nil }

        return (accountKey, threadID)
    }

    // MARK: - Writing

    private func add(_ rows: some Collection<FeedEntrySnapshot>) async {
        guard rows.isEmpty == false else { return }

        var items: [CSSearchableItem] = []
        var dates: [String: Date] = [:]

        for row in rows {
            guard
                let message = try? await store.message(
                    emailID: row.emailID, accountKey: row.accountKey)
            else { continue }

            let attributes = CSSearchableItemAttributeSet(contentType: .message)
            attributes.title = message.subject
            attributes.contentDescription = message.preview
            attributes.authorNames = [message.displayName]
            attributes.authorEmailAddresses = message.fromAddress.map { [$0] }
            attributes.contentCreationDate = message.receivedAt ?? row.sortDate

            items.append(
                CSSearchableItem(
                    uniqueIdentifier: Self.uid(for: row),
                    domainIdentifier: Self.domain,
                    attributeSet: attributes))

            dates[Self.uid(for: row)] = row.sortDate
        }

        guard items.isEmpty == false else { return }

        do {
            try await index.indexSearchableItems(items)
            indexed.merge(dates) { _, new in new }
            writeRecord()
        } catch {
            // Nothing is recorded on failure, so the next pass tries the same
            // rows again. The alternative — recording optimistically — leaves
            // mail permanently absent from search with no way to notice.
            Self.logger.error("Could not index \(items.count) items: \(error, privacy: .public)")
        }
    }

    private func removeVanished(keeping rows: [FeedEntrySnapshot]) async {
        let gone = Self.vanished(from: rows, alreadyIndexed: indexed)

        guard gone.isEmpty == false else { return }

        do {
            try await index.deleteSearchableItems(withIdentifiers: gone)

            for uid in gone { indexed.removeValue(forKey: uid) }

            writeRecord()
        } catch {
            Self.logger.error("Could not remove \(gone.count) items: \(error, privacy: .public)")
        }
    }

    /// Everything, on sign-out.
    ///
    /// By domain rather than by id: sign-out deletes the store in the same
    /// breath, so by the time anyone thought to enumerate the ids there would
    /// be nothing left to enumerate them from.
    func removeEverything() async {
        indexed = [:]
        writeRecord()

        do {
            try await index.deleteSearchableItems(withDomainIdentifiers: [Self.domain])
        } catch {
            Self.logger.error("Could not clear the index: \(error, privacy: .public)")
        }
    }

    // MARK: - The record

    private static func readRecord(from defaults: UserDefaults) -> [String: Date] {
        let stored = defaults.dictionary(forKey: recordKey) as? [String: Double] ?? [:]

        return stored.mapValues { Date(timeIntervalSince1970: $0) }
    }

    private func writeRecord() {
        defaults.set(
            indexed.mapValues { $0.timeIntervalSince1970 },
            forKey: Self.recordKey)
    }
}
