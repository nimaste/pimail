import Foundation
import JMAPKit
import OSLog

/// Object-level sync: what changed, rather than what order things are in.
///
/// The two halves of staying current are deliberately separate. ``UnifiedFeed``
/// owns *ordering* and pages it; this owns *objects* and updates them in
/// place. A message being marked read in another client changes the object and
/// not its position, so pushing that through the feed would be re-querying an
/// entire list to learn one boolean.
public actor DeltaSync {
    /// The server caps `/changes` at 256 rows per call and sets
    /// `hasMoreChanges` — deliberately modest for mobile, so callers loop.
    static let maxLoops = 40

    /// Chunk size for hydrating changed ids.
    ///
    /// Well under the 500 the server permits: it hydrates full Doctrine
    /// entities per message, and asking for 500 at once on a Raspberry Pi is
    /// unkind for no gain.
    static let getChunk = 100

    private let client: JMAPClient
    private let store: SyncStore
    /// Read before any list is rewritten from the server.
    ///
    /// A conversation the user archived on a train is still in the Inbox as far
    /// as the server is concerned, so projecting the server's answer would put
    /// the row back on screen and make the gesture look as though it had been
    /// ignored. Nil only in tests that have no queue.
    private let queue: ActionQueue?
    private let logger = Logger(subsystem: "de.plmail", category: "delta")

    public init(client: JMAPClient, store: SyncStore, queue: ActionQueue? = nil) {
        self.client = client
        self.store = store
        self.queue = queue
    }

    public struct Outcome: Sendable {
        /// Accounts whose ordering may have moved, so their feeds want a
        /// refresh. Empty means nothing arrived and no list need be touched.
        public var accountsWithNewMail: Set<String> = []
        /// Accounts whose cursor was too old to answer and were re-paged.
        public var resyncedAccounts: Set<String> = []
        public var failures: [String: String] = [:]

        public var isEmpty: Bool {
            accountsWithNewMail.isEmpty && resyncedAccounts.isEmpty
        }
    }

    /// Pulls every account up to date.
    @discardableResult
    public func pull(accounts: [AccountSnapshot]) async -> Outcome {
        var outcome = Outcome()

        for account in accounts {
            do {
                let changed = try await pullChanges(for: account)

                if changed { outcome.accountsWithNewMail.insert(account.accountKey) }
            } catch let error as JMAPError where error.requiresResync {
                // The one path that throws away a cursor. Everything else is
                // recoverable by asking again later.
                logger.notice(
                    "\(account.accountKey, privacy: .public) cursor too old; re-paging.")
                try? await store.clearCursors(accountKey: account.accountKey)
                outcome.resyncedAccounts.insert(account.accountKey)
            } catch {
                outcome.failures[account.accountKey] = String(describing: error)
                logger.error(
                    "\(account.accountKey, privacy: .public): \(error, privacy: .public)")
            }
        }

        return outcome
    }

    /// - Returns: Whether anything changed for this account.
    private func pullChanges(for account: AccountSnapshot) async throws -> Bool {
        // "0" is always answerable: plMail's change log shares one sequence
        // across every (account, type), so a type's first row can sit at any
        // number and a fresh client must not be told to resync.
        var since = account.emailState ?? .initial
        var touched = false
        var loops = 0

        while loops < Self.maxLoops {
            loops += 1

            let session = try await client.session()
            var builder = RequestBuilder(session: session)

            let changes = builder.add(
                EmailChanges(accountID: account.accountID, sinceState: since, maxChanges: 256))

            let results = try await client.send(builder)

            if let failure = results.failure(of: changes) { throw failure }

            let result = try results.result(of: changes)

            let updated = result.created + result.updated

            if updated.isEmpty == false {
                try await hydrate(updated, account: account)
                touched = true
            }

            if result.destroyed.isEmpty == false {
                try await store.removeEmails(
                    result.destroyed.map(\.rawValue), accountKey: account.accountKey)
                touched = true
            }

            since = result.newState
            try await store.setEmailState(since, accountKey: account.accountKey)

            guard result.hasMoreChanges else { break }
        }

        if loops >= Self.maxLoops {
            // Ten thousand changes means this client has been away long
            // enough that paging afresh is cheaper than catching up.
            logger.notice("\(account.accountKey, privacy: .public) too far behind; re-paging.")
            try? await store.clearCursors(accountKey: account.accountKey)
        }

        return touched
    }

    /// Fetches changed messages and the threads they belong to.
    private func hydrate(_ ids: [EmailID], account: AccountSnapshot) async throws {
        for chunk in stride(from: 0, to: ids.count, by: Self.getChunk) {
            let slice = Array(ids[chunk..<min(chunk + Self.getChunk, ids.count)])
            let session = try await client.session()
            var builder = RequestBuilder(session: session)

            let get = builder.add(
                EmailGet(
                    accountID: account.accountID,
                    ids: .value(slice),
                    properties: EmailGet.listRowProperties
                )
            )
            let threads = builder.add(
                ThreadGet(
                    accountID: account.accountID,
                    ids: .reference(get.reference(path: "/list/*/threadId"))
                )
            )

            let results = try await client.send(builder)
            let threadList = try results.result(of: threads).list

            try await store.upsert(
                emails: try results.result(of: get).list,
                threads: threadList,
                accountKey: account.accountKey,
                emailState: nil
            )

            // Immediately after the write, like Android's `FeedProjection`, and
            // for the same reason: the thread rows carry the mailbox bindings
            // that were written moments ago, and any list not reconciled now
            // goes on showing a conversation that has since been archived
            // somewhere else.
            await project(threadIDs: threadList.map(\.id.rawValue), account: account)
        }
    }

    /// Reconciles every list this account has paged with what it now holds.
    ///
    /// Failure is swallowed on purpose: a projection that cannot run leaves the
    /// lists as stale as they were before this existed, whereas throwing would
    /// abandon the delta cursor advance and make the next pull re-fetch
    /// everything it just wrote.
    private func project(threadIDs: [String], account: AccountSnapshot) async {
        do {
            let feeds =
                try await store.pagedFeeds(accountKey: account.accountKey)
                .compactMap { paged -> (feed: FeedID, cursor: FeedCursorSnapshot)? in
                    guard let feed = FeedID(rawValue: paged.feedID), feed.isSearch == false
                    else { return nil }

                    return (feed, paged.cursor)
                }

            guard feeds.isEmpty == false, threadIDs.isEmpty == false else { return }

            let mailboxes = try await store.mailboxes(accountKey: account.accountKey)
            let pendingTargets = await queue?.pendingTargets() ?? []

            let projections = try await store.threadProjections(
                threadIDs: threadIDs, accountKey: account.accountKey)

            var changes: [FeedProjectionChange] = []

            for projection in projections {
                changes += FeedProjection.changes(
                    threadID: projection.threadID,
                    accountKey: account.accountKey,
                    mailboxIDs: projection.mailboxIDs,
                    sortDate: projection.sortDate,
                    newestEmailID: projection.newestEmailID,
                    feeds: feeds,
                    mailboxes: mailboxes,
                    pendingTargets: pendingTargets,
                    category: projection.category
                )
            }

            try await store.applyProjection(changes)
        } catch {
            logger.error(
                "Could not project \(account.accountKey, privacy: .public): \(error, privacy: .public)"
            )
        }
    }
}
