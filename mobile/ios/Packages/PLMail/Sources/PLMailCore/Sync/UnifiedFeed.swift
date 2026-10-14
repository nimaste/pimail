import Foundation
import JMAPKit
import OSLog

/// Merges several paged accounts into one date-ordered list.
///
/// There is no server-side cross-account query — one JMAP account per
/// connected mailbox — so the unified inbox is this: one `Email/query` per
/// account, merged client-side on `receivedAt`.
///
/// The merge is a k-way merge over buffered sources, and the invariant is the
/// whole correctness argument:
///
/// > **Before any row may be emitted, every source must either have a visible
/// > head or be known-exhausted.**
///
/// Emitting while a source's buffer is empty but its stream is not would emit
/// past a row that source was about to produce, and that row would then appear
/// below rows older than it — or, once the feed table is persisted, never
/// appear at all.
///
/// The second subtlety is where the persisted cursor sits. It advances on
/// **emit**, not on fetch. A page fetched but not yet emitted is buffered in
/// memory only, so if the app is killed mid-scroll the next launch re-fetches
/// those rows rather than resuming past them and leaving a hole in the list.
public actor UnifiedFeed {
    private struct Source {
        let pager: AccountPager

        /// Where the *persisted* position sits: the last row actually emitted.
        var emitted: FeedCursorSnapshot
        /// Where the next fetch starts. Runs ahead of `emitted` by whatever is
        /// still buffered.
        var fetch: FeedCursorSnapshot
        var buffer: [FeedRow] = []
        /// The server has no more rows *and* the buffer is drained.
        var isDrained = false
        var failure: String?

        var isUsable: Bool { failure == nil && isDrained == false }
        var head: FeedRow? { buffer.first }

        /// Moves the persisted cursor onto a row that has just been emitted.
        ///
        /// Boundary ids are the rows already emitted at exactly this
        /// timestamp. `before` is a strict `<`, so the next page asks for one
        /// second later and filters these out — without them, messages
        /// sharing a second across a page boundary are silently dropped.
        mutating func advanceEmitted(to row: FeedRow) {
            if emitted.lastSortDate == row.sortDate {
                emitted.boundaryIDs.insert(row.emailID)
            } else {
                emitted.lastSortDate = row.sortDate
                emitted.boundaryIDs = [row.emailID]
            }

            emitted.isExhausted = false
        }
    }

    private let feedID: FeedID
    private let client: JMAPClient
    private let store: SyncStore
    private let logger = Logger(subsystem: "de.plmail", category: "feed")

    private var sources: [String: Source] = [:]

    public init(feedID: FeedID, client: JMAPClient, store: SyncStore) {
        self.feedID = feedID
        self.client = client
        self.store = store
    }

    /// Accounts that failed while others succeeded, keyed by account key.
    ///
    /// One unreachable account must never blank the list: with three mailboxes
    /// connected that is the difference between "my work mail is down" and
    /// "the app is broken".
    public private(set) var failures: [String: String] = [:]

    // MARK: - Setup

    /// Restores each account's position from the store.
    public func prepare(pagers: [AccountPager]) async {
        var restored: [String: Source] = [:]

        for pager in pagers {
            let cursor =
                (try? await store.cursor(feedID: feedID.rawValue, accountKey: pager.accountKey))
                ?? FeedCursorSnapshot()

            // Carrying the previous buffer would be wrong: the pagers may have
            // changed, and the buffer is deliberately not durable state.
            restored[pager.accountKey] = Source(
                pager: pager,
                emitted: cursor,
                fetch: cursor,
                isDrained: cursor.isExhausted
            )
        }

        sources = restored
        failures = [:]
    }

    /// Re-fetches the head of every account and splices it in.
    ///
    /// Not a rebuild. The tail of the list — everything already paged past —
    /// is left exactly where it is, so a refresh does not lose the reader's
    /// place and does not re-query pages the server has already served once.
    ///
    /// An account whose fresh head shares nothing with what was stored has
    /// moved further than one page, and the rows between old and new are
    /// unknown. There the feed is dropped and rebuilt, because splicing would
    /// leave an invisible gap.
    public func refreshHead() async {
        failures = [:]

        for (key, source) in sources {
            do {
                let page = try await source.pager.page(after: FeedCursorSnapshot(), using: client)

                try await store.upsert(
                    emails: page.emails,
                    threads: page.threads,
                    accountKey: key,
                    emailState: page.emailState
                )

                let boundary = page.rows.last?.sortDate ?? .distantPast

                let overlaps = try await store.spliceFeedHead(
                    page.rows, feedID: feedID.rawValue, accountKey: key, from: boundary)

                var updated = source

                if overlaps {
                    // The tail is still reachable, so only the fetch position
                    // needs rewinding to just past the fresh head.
                    updated.buffer = []
                    // Keep the deeper position. Rewinding to the fresh head
                    // would re-fetch every page already paged past, which is
                    // the cost this splice exists to avoid.
                    if source.fetch.lastSortDate == nil {
                        updated.fetch = page.cursor
                    }
                } else {
                    try await store.resetFeed(feedID: feedID.rawValue, accountKey: key)
                    try await store.spliceFeedHead(
                        page.rows, feedID: feedID.rawValue, accountKey: key, from: .distantPast)

                    updated.buffer = []
                    updated.emitted = page.cursor
                    updated.fetch = page.cursor
                    logger.notice("\(key, privacy: .public) moved past a page; feed rebuilt.")
                }

                updated.isDrained = page.cursor.isExhausted && updated.buffer.isEmpty
                updated.failure = nil
                sources[key] = updated
            } catch {
                var degraded = source
                degraded.failure = String(describing: error)
                sources[key] = degraded
                failures[key] = describe(error)
                logger.error("\(key, privacy: .public) refresh failed: \(error, privacy: .public)")
            }
        }
    }

    // MARK: - Paging

    /// Emits the next `count` rows in global date order and persists them.
    ///
    /// - Returns: How many rows were emitted. Zero means the list is complete.
    @discardableResult
    public func loadMore(count: Int = AccountPager.pageSize) async -> Int {
        var emitted: [String: [FeedRow]] = [:]
        var total = 0

        while total < count {
            await refillEmptyBuffers()

            // The invariant: only sources that are drained or failed may have
            // an empty buffer at this point.
            guard let next = nextSource() else { break }

            guard var source = sources[next], let row = source.buffer.first else { break }

            source.buffer.removeFirst()
            source.advanceEmitted(to: row)
            source.isDrained = source.buffer.isEmpty && source.fetch.isExhausted
            // Recorded so a relaunch knows not to ask this account again.
            source.emitted.isExhausted = source.isDrained
            sources[next] = source

            emitted[next, default: []].append(row)
            total += 1
        }

        await persist(emitted)

        return total
    }

    /// Refills every usable source whose buffer has run dry.
    ///
    /// Concurrently, through the client's shared gate: with N accounts this is
    /// one round trip's latency rather than N, which over a home uplink is the
    /// difference between a list that scrolls and one that stutters.
    private func refillEmptyBuffers() async {
        let hungry = sources.filter { $0.value.isUsable && $0.value.buffer.isEmpty }

        guard hungry.isEmpty == false else { return }

        let pages = await withTaskGroup(
            of: (String, Result<AccountPager.Page, any Error>).self
        ) { group in
            for (key, source) in hungry {
                group.addTask { [client, pager = source.pager, cursor = source.fetch] in
                    do {
                        return (key, .success(try await pager.page(after: cursor, using: client)))
                    } catch {
                        return (key, .failure(error))
                    }
                }
            }

            var collected: [(String, Result<AccountPager.Page, any Error>)] = []

            for await result in group {
                collected.append(result)
            }

            return collected
        }

        for (key, outcome) in pages {
            guard var source = sources[key] else { continue }

            switch outcome {
            case .success(let page):
                source.buffer.append(contentsOf: page.rows)
                source.fetch = page.cursor
                source.isDrained = source.buffer.isEmpty && page.cursor.isExhausted
                sources[key] = source

                // Cache the page's content regardless of whether its rows are
                // emitted yet: an email is worth having either way, and it is
                // what lets the row render the moment it is emitted.
                try? await store.upsert(
                    emails: page.emails,
                    threads: page.threads,
                    accountKey: key,
                    emailState: page.emailState
                )

            case .failure(let error):
                // Degrade this source and carry on. The merge stays correct
                // for the remaining accounts; it is simply missing one.
                source.failure = String(describing: error)
                sources[key] = source
                failures[key] = describe(error)
                logger.error("\(key, privacy: .public) degraded: \(error, privacy: .public)")
            }
        }
    }

    /// The source whose head is newest. Nil when nothing can be emitted.
    private func nextSource() -> String? {
        sources
            .compactMap { key, source in source.head.map { (key, $0.sortDate) } }
            .max { $0.1 < $1.1 }?
            .0
    }

    /// Writes the emitted rows and every source's cursor.
    ///
    /// Cursors are written even for sources that emitted nothing, because a
    /// source becoming exhausted is itself state worth keeping: without it, a
    /// relaunch re-queries an account that has already run out.
    private func persist(_ emitted: [String: [FeedRow]]) async {
        for (key, source) in sources {
            guard source.failure == nil else { continue }

            try? await store.appendFeedRows(
                emitted[key] ?? [],
                feedID: feedID.rawValue,
                accountKey: key,
                cursor: source.emitted
            )
        }
    }

    private func describe(_ error: any Error) -> String {
        guard let error = error as? JMAPError else { return error.localizedDescription }

        switch error {
        case .notAuthenticated:
            return String(localized: "Sign-in is no longer valid.", bundle: .module)
        case .unreachable(let host, _):
            return String(localized: "Can't reach \(host).", bundle: .module)
        default:
            return String(localized: "This account didn't sync.", bundle: .module)
        }
    }
}
