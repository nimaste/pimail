import Foundation
import JMAPKit
import OSLog
import Observation

/// Drives syncing for the connected server.
///
/// Owns the account and mailbox structure, and one ``UnifiedFeed`` per list.
/// The merge is what makes several accounts read as one inbox; this type is
/// what decides which accounts and which mailboxes go into it.
///
/// Delta sync through `Email/changes` slots in alongside: it updates objects,
/// where the merge owns ordering.
@MainActor
@Observable
public final class MailSyncService {
    public enum Status: Equatable, Sendable {
        case idle
        case syncing
        /// The server answered, and said no. Distinct from `failed` because
        /// the remedy is different: a revoked app password is not something
        /// retrying fixes, and presenting it as a network problem sends the
        /// user to check their wifi instead of their credential.
        case unauthenticated
        case failed(message: String)
    }

    public private(set) var status: Status = .idle
    public private(set) var accounts: [AccountSnapshot] = []
    public private(set) var mailboxes: [MailboxSnapshot] = []

    /// Accounts that failed while others succeeded.
    ///
    /// One unreachable account must not blank the whole list — with several
    /// mailboxes connected, that is the difference between "my work mail is
    /// down" and "the app is broken".
    public private(set) var degradedAccounts: [String: String] = [:]

    /// Whether this server classifies mail into inbox categories at all.
    ///
    /// **False until proven otherwise, and that is the safe direction.** A
    /// plMail instance whose classifier has never run answers every category
    /// query with nothing, and five permanently empty tabs above a working
    /// inbox reads as mail having gone missing. Starting false means the
    /// control cannot flicker in on launch and out again the way an optional
    /// would.
    ///
    /// Re-read on every cache load rather than on a timer, so it is refreshed
    /// by exactly the things that could change it — a sync, a foreground, a
    /// delta pull — and never by anything else.
    public private(set) var hasCategories = false

    /// Highlighted match text, keyed by `accountKey#emailId`.
    ///
    /// In memory rather than in the store: it belongs to one query rather than
    /// to the message, it is meaningless the moment the search text changes,
    /// and the store's rule is that everything in it is reconstructible cache
    /// — this is reconstructible, but only alongside a query nobody kept.
    public private(set) var highlights: [String: SearchHighlight] = [:]

    /// The body half alone, for the row's preview slot.
    ///
    /// Two fields rather than `preview ?? subject` collapsed into one: a
    /// subject match drawn in the body-snippet slot shows the same words twice
    /// on one row, once as the subject and once as what is supposed to be the
    /// sentence they were found in. A row that has no body match now draws its
    /// own stored preview instead, which is at least honest.
    public var snippets: [String: String] {
        highlights.compactMapValues(\.body)
    }

    /// One merge per feed, so each keeps its own buffers and cursors.
    private var merges: [FeedID: UnifiedFeed] = [:]
    /// Which accounts each merge was built for. A change means it has to be
    /// rebuilt — an account added or removed changes what is being merged.
    private var mergedAccounts: [FeedID: Set<String>] = [:]

    /// When the server was last successfully reached.
    ///
    /// Shown as "last checked" rather than implying live delivery. Without
    /// APNs there is no true background push, and a client that suggests
    /// otherwise is lying about mail the user has not been told about.
    public private(set) var lastCheckedAt: Date?

    private let connection: ServerConnection
    private let client: JMAPClient
    /// Exposed because views that mutate — the label picker — need to read
    /// back what the store actually holds after an action, rather than
    /// assuming their optimistic change stuck.
    public let store: SyncStore
    private let delta: DeltaSync
    private let breaker: CircuitBreaker
    private let events: EventSourceClient
    private let logger = Logger(subsystem: "de.plmail", category: "sync")

    /// Which feed is on screen, so a push refreshes that list and not every
    /// list the app has ever built.
    private var visibleFeed: FeedID?

    /// Actions taken while the server could not be reached.
    ///
    /// Claimed here rather than built by whoever needs it: ``MailActions`` is
    /// constructed by a view that is handed a client and a store and no server
    /// id, and two queues over one directory would drain the same file twice.
    private let queue: ActionQueue
    private let drain: ActionDrain

    /// The write half of the New marker.
    ///
    /// Owned here rather than by the list, because a list is rebuilt every time
    /// the mailbox changes and the batch it was holding would go with it — the
    /// reports for the last page drawn would be dropped exactly at the moment
    /// somebody navigated away, which is when they matter most.
    private let shown: ShownThreads

    public init(connection: ServerConnection, store: SyncStore) {
        self.connection = connection
        let client = connection.makeClient()
        self.client = client
        self.store = store
        let queue = ActionQueue.shared(serverID: connection.host)
        self.queue = queue
        drain = ActionDrain(queue: queue)
        // The queue is handed to delta sync as well: a feed projection that did
        // not consult it would put back on screen the conversation the user
        // archived a minute ago, and the gesture would look ignored.
        delta = DeltaSync(client: client, store: store, queue: queue)
        breaker = CircuitBreaker()
        events = EventSourceClient(client: client, credential: connection.credential)
        shown = ShownThreads(client: client, store: store)
    }

    // MARK: - The New marker

    /// Reports that a conversation's row has been drawn.
    ///
    /// **Only from a genuine display.** A page arriving from the pager, a delta
    /// pull, a notification and the body prefetcher all put conversations on
    /// this device without anybody seeing them; reporting those would retire
    /// markers for mail the user has never looked at, in every client they own.
    ///
    /// Returns immediately — the batching and the round trip happen behind
    /// ``ShownThreads``, and a scroll must never wait on a home server.
    public func reportDisplayed(threadID: String, accountKey: String) {
        guard let accountID = accounts.first(where: { $0.accountKey == accountKey })?.accountID
        else { return }

        Task { [shown] in
            await shown.report(
                threadID: threadID, accountKey: accountKey, accountID: accountID)
        }
    }

    /// Sends whatever displays are still batched, without waiting out the
    /// debounce.
    ///
    /// For the moment a list goes away — a mailbox change, or the scene leaving
    /// the foreground — where the alternative is a page's worth of reports
    /// dropped because the window had 300ms left on it.
    public func flushDisplayReports() async {
        await shown.flushNow()
    }

    public var serverID: String { connection.host }

    /// Shared with the reader so both go through one cached session and one
    /// concurrency gate. A second client would mean a second session fetch and
    /// a gate that does not know about the other's in-flight requests.
    public var jmapClient: JMAPClient { client }
    public var serverConnection: ServerConnection { connection }

    /// Called when the user asks to replace a credential the server rejected.
    ///
    /// **Not a sign-out.** It was wired to one, and the cost was every cached
    /// message and every queued draft each time an app password was revoked,
    /// rotated or expired. Whoever sets this must present a way to supply a new
    /// credential for the *same* server and must not touch ``store`` — the
    /// cache is keyed by server and account and stays valid across the swap.
    public var onReauthenticationNeeded: (() -> Void)?

    public func requestReauthentication() {
        onReauthenticationNeeded?()
    }

    /// What to say over a list that still has cached mail in it.
    ///
    /// Nil when there is nothing worth interrupting for — a successful sync,
    /// or one still in flight.
    public var bannerMessage: String? {
        switch status {
        case .idle, .syncing: nil
        case .unauthenticated: "\(serverID) rejected this app password."
        case .failed(let message): message
        }
    }

    // MARK: - Liveness

    /// Starts listening for changes.
    ///
    /// Foreground only, and only while a list is actually on screen. Each
    /// connection holds a PHP worker for its life, and on a home NAS the pool
    /// is small enough that an idle app keeping one open is a real cost to
    /// everyone else using the server.
    public func beginLiveUpdates(feed: FeedID) async {
        visibleFeed = feed

        await events.start { [weak self] change in
            await self?.handle(change)
        } onConnection: { [weak self] connected in
            await self?.setLive(connected)
        }
    }

    // MARK: - Warming what is on screen

    /// Message ids this session has already asked the server for.
    ///
    /// Not "already has", which the store answers: this is the guard against
    /// asking twice for the same message while the first request is still in
    /// flight, and against re-asking forever for a message the server has no
    /// body for. It is per-session and unbounded on purpose — a mailbox is
    /// tens of thousands of short ids, and the alternative is a request loop.
    @ObservationIgnored private var warmed: Set<String> = []
    @ObservationIgnored private var isWarming = false

    /// Fetches bodies for messages that are **on screen right now**.
    ///
    /// The background prefetcher takes the newest fifty messages in an account
    /// and works down. That is the right shape for a commute and the wrong one
    /// for a person scrolling: they are five hundred rows into an inbox, and
    /// the fifty newest messages — most of them in Updates or Promotions — are
    /// not the ones under their thumb. So the list says which rows it is
    /// actually showing and this fetches those, which is the only set that
    /// makes "tap a conversation and it is there" true by construction.
    ///
    /// Politeness comes from the caller rather than from a budget: a screen
    /// holds about fifteen rows, so a chunk of twenty covers a screenful and a
    /// bit in one round trip. Ids already asked for this session are dropped,
    /// so scrolling back over the same rows costs nothing.
    public func warmBodies(accountKey: String, emailIDs: [String]) async {
        let fresh = emailIDs.filter { warmed.contains($0) == false }

        guard fresh.isEmpty == false, isWarming == false else { return }
        guard let account = accounts.first(where: { $0.accountKey == accountKey }) else { return }

        let wanted: [String]

        do {
            wanted = try await store.emailsWithoutBody(among: fresh, accountKey: accountKey)
        } catch {
            return
        }

        guard wanted.isEmpty == false else {
            // Nothing missing is still an answer: remember it so the same rows
            // scrolling past again ask the store nothing.
            warmed.formUnion(fresh)

            return
        }

        isWarming = true
        defer { isWarming = false }

        // Recorded before the request, not after. A message the server returns
        // no body for must not become a candidate again on the next scroll.
        warmed.formUnion(wanted)

        // Only worth announcing when there is something to announce. A screen
        // whose last two rows needed topping up is not "downloading for
        // offline"; a bar that flashed on every scroll stop would be the kind
        // of indicator people learn to stop seeing.
        let isWorthShowing = wanted.count >= 5

        if isWorthShowing { reportWarming(fetched: 0, remaining: wanted.count) }

        do {
            let session = try await client.session()
            var builder = RequestBuilder(session: session)

            let get = builder.add(
                EmailGet(
                    accountID: account.accountID,
                    ids: .value(wanted.map { EmailID($0) }),
                    properties: EmailGet.readerProperties))

            let emails = try await client.send(builder).result(of: get).list

            try await store.storeReaderContent(emails, accountKey: accountKey)

            if isWorthShowing { reportWarming(fetched: emails.count, remaining: 0) }
        } catch {
            logger.error("Warming visible bodies failed: \(error, privacy: .public)")
        }

        if isWorthShowing { finishWarming() }
    }

    /// The indicator, where there is one. `PrefetchActivity` is a view-layer
    /// concern and iOS-only; the fetch it reports is neither, so the reporting
    /// is what carries the `#if`.
    private func reportWarming(fetched: Int, remaining: Int) {
        #if os(iOS)
        PrefetchActivity.shared.report(fetched: fetched, remaining: remaining)
        #endif
    }

    private func finishWarming() {
        #if os(iOS)
        PrefetchActivity.shared.finish()
        #endif
    }

    /// Stops listening. Called the moment the app stops being frontmost.
    public func endLiveUpdates() async {
        await events.stop()
        isLive = false
    }

    /// Whether the change stream is **open right now**.
    ///
    /// The one fact the web UI puts in its header dot, and the one this app's
    /// header dot was not carrying: it showed whether the last *poll* had
    /// succeeded, which stays green on a server whose event stream has been
    /// refused for an hour. Live means changes made in a browser land here
    /// without anybody pressing anything.
    ///
    /// False while the app is in the background, which is correct rather than
    /// pessimistic — the stream is deliberately closed there, because each one
    /// holds a PHP worker.
    public private(set) var isLive = false

    private func setLive(_ live: Bool) {
        isLive = live
    }

    /// A push says only that a state token moved; this finds out what.
    ///
    /// **Only the accounts that actually moved.** One bulk label edit in the
    /// browser produces dozens of `StateChange` events naming the same token,
    /// and pulling for each of them costs an `Email/changes` round trip apiece
    /// against a server with one PHP worker pool. The token the event carries
    /// is compared against the one this device already holds, and a match means
    /// there is nothing to ask for.
    private func handle(_ change: StateChange) async {
        // First statement on purpose, ahead of the "did anything move" filter:
        // a change that moved nothing is still evidence the stream is alive,
        // and a push log that only recorded consequential changes would look
        // dead exactly when somebody is trying to find out whether it is.
        await PushActivityLog.shared.record(change, route: .stream)

        let moved = Self.accountsThatMoved(change, accounts: accounts)

        guard moved.isEmpty == false else {
            // Still evidence the server is up and answering, which is worth
            // recording — but not worth a request.
            lastCheckedAt = .now

            return
        }

        let outcome = await delta.pull(accounts: moved)

        lastCheckedAt = .now

        guard outcome.isEmpty == false, let visibleFeed else { return }

        // New mail can change ordering, so the visible list gets a spliced
        // head — never a full re-query, which is the aggressive polling the
        // server cannot afford.
        let merge = await merge(for: visibleFeed)
        await merge.refreshHead()

        for accountKey in outcome.resyncedAccounts {
            logger.notice("\(accountKey, privacy: .public) was re-paged after a stale cursor.")
        }
    }

    /// Which accounts a state change actually concerns.
    ///
    /// An account the event does not name at all is included: plMail sends the
    /// full map today, but a server that omitted an account would otherwise
    /// have its mail silently never pulled, and missing mail is a far worse
    /// failure than one extra request. An account the event names with the
    /// token this device already holds is skipped — that is the whole saving.
    nonisolated static func accountsThatMoved(
        _ change: StateChange, accounts: [AccountSnapshot]
    ) -> [AccountSnapshot] {
        accounts.filter { account in
            guard let announced = change.changed[account.accountID.rawValue]?["Email"] else {
                return true
            }

            return announced != account.emailState?.rawValue
        }
    }

    /// One delta pass, for a background refresh.
    ///
    /// No paging and no bodies: the point is to learn what changed cheaply,
    /// matching the server's own fifteen-minute poll rather than trying to
    /// beat it.
    public func refreshInBackground() async {
        guard await breaker.isOpen == false else { return }

        do {
            try await breaker.run(attempts: 2) { [self] in
                _ = try await client.session()
            }

            await loadCached()
            // Before the pull, not after: a sync that wrote the server's answer
            // over a change still waiting to be sent would take the row off
            // screen again and look like the gesture had been undone.
            await drainQueuedActions()
            _ = await delta.pull(accounts: accounts)
            lastCheckedAt = .now
        } catch {
            logger.error("Background refresh failed: \(error, privacy: .public)")
        }
    }

    /// Called when the network path changes — the one signal worth reopening a
    /// tripped circuit for, since time passing is not evidence of anything.
    ///
    /// - Parameter isOnline: Whether the device has a *validated* path. Android
    ///   reads `NET_CAPABILITY_VALIDATED` for the same reason: a captive portal
    ///   answers every connection and none of them reach the mail server, and
    ///   telling the user their NAS is down when the hotel wifi wants a login is
    ///   sending them to fix the wrong thing. Defaults to true so a caller that
    ///   only knows "something changed" behaves as it always has.
    public func networkPathChanged(isOnline: Bool = true) async {
        isDeviceOffline = isOnline == false

        await breaker.allowRetry()

        guard isOnline else { return }

        await drain.allowRetry()
        await drainQueuedActions()
    }

    // MARK: - Offline durability

    /// Whether this device has no usable network.
    ///
    /// Kept apart from ``degradedAccounts`` because the remedy is different and
    /// the sentence has to be: when the phone is offline every account fails for
    /// the same reason, and listing five "couldn't reach nas.local" banners
    /// implies five separate faults.
    public private(set) var isDeviceOffline = false

    /// How many changes are waiting to reach the server.
    public private(set) var queuedActionCount = 0

    /// What the list should say over the top of the mail it already has.
    ///
    /// Three cases, deliberately distinct — the same three Android chose,
    /// because each one sends the user somewhere different.
    public enum OfflineState: Equatable, Sendable {
        /// Everything is current.
        case current
        /// This device has no network. Per-account banners are suppressed:
        /// they are all failing for this one reason.
        case deviceOffline(queued: Int)
        /// The device has a network and *nothing* on the server answered.
        /// Naming one account would imply the others are fine.
        case wholeServer(host: String, queued: Int)
        /// One account failed and the rest are still refreshing.
        case account(accountKey: String, message: String, queued: Int)

        /// The sentence to show. Written here rather than in the view so the
        /// three cases cannot be worded into meaning the same thing.
        public var message: String? {
            switch self {
            case .current:
                nil
            case .deviceOffline:
                String(localized: "You're offline.", bundle: .module)
            case .wholeServer(let host, _):
                String(localized: "Nothing on \(host) answered.", bundle: .module)
            case .account(_, let message, _):
                message
            }
        }

        /// How many changes are waiting behind this state.
        public var queued: Int {
            switch self {
            case .current: 0
            case .deviceOffline(let queued): queued
            case .wholeServer(_, let queued): queued
            case .account(_, _, let queued): queued
            }
        }

        /// Whether a Retry button makes sense.
        ///
        /// Not while the device is offline: pressing it can only fail, and a
        /// button that cannot work is worse than none.
        public var isRetryable: Bool {
            switch self {
            case .current, .deviceOffline: false
            case .wholeServer, .account: true
            }
        }
    }

    public var offlineState: OfflineState {
        if isDeviceOffline { return .deviceOffline(queued: queuedActionCount) }

        guard let first = degradedAccounts.sorted(by: { $0.key < $1.key }).first else {
            return .current
        }

        if accounts.isEmpty == false, degradedAccounts.count >= accounts.count {
            return .wholeServer(host: serverID, queued: queuedActionCount)
        }

        return .account(
            accountKey: first.key, message: first.value, queued: queuedActionCount)
    }

    /// Sends whatever is waiting, oldest first.
    ///
    /// **Never on a timer and never eagerly.** It runs when something suggests
    /// the server is worth talking to again — the network path changed, a sync
    /// succeeded, the user pulled to refresh — and ``ActionDrain`` backs off
    /// between failures. This audience runs the server on a Raspberry Pi with a
    /// single worker pool, and a queue retried in a loop takes the web UI down
    /// with it.
    public func drainQueuedActions() async {
        let summary = await drain.drain { [weak self] mutation in
            guard let self else { return .unreachable }

            return await send(mutation)
        }

        queuedActionCount = summary.remaining

        if summary.refused > 0 {
            logger.error("The server refused \(summary.refused, privacy: .public) queued actions.")
        }
    }

    /// Re-reads the count without sending anything, for a screen coming
    /// forward.
    public func refreshQueuedCount() async {
        queuedActionCount = await queue.count()
    }

    /// Replays one queued mutation.
    ///
    /// A label is re-resolved to this account's binding here rather than being
    /// carried: a binding id belongs to one account and can be recreated with a
    /// different number when a label is deleted and remade, so a queue holding
    /// one would eventually apply the wrong label. A label that no longer
    /// resolves is counted as sent — a queue that cannot empty blocks every
    /// action behind it forever.
    private func send(_ mutation: PendingMutation) async -> ActionDrain.Attempt {
        guard accounts.contains(where: { $0.accountKey == mutation.accountKey }) else {
            // The account was disconnected while this waited. It can never
            // accept its backlog, and retrying would stall everything behind
            // it — the drain stops at the first failure by design.
            return .sent
        }

        if case .snooze(let until) = mutation.kind {
            return await send(
                ThreadSet.snooze(
                    ThreadID(mutation.threadID), until: until.map(UTCDate.init),
                    accountID: mutation.accountID))
        }

        guard let request = await request(for: mutation) else { return .sent }

        return await send(request)
    }

    /// The wire call for a queued mutation, or nil when it no longer means
    /// anything in this account.
    private func request(for mutation: PendingMutation) async -> EmailSet? {
        let accountKey = mutation.accountKey
        let ids = mutation.emailIDs
        let accountID = mutation.accountID

        switch mutation.kind {
        case .archive:
            guard let inbox = try? await store.mailbox(role: .inbox, accountKey: accountKey)
            else { return nil }

            return EmailSet.archive(
                ids: ids, inbox: inbox,
                archive: try? await store.mailbox(role: .archive, accountKey: accountKey),
                accountID: accountID)

        case .moveToInbox:
            guard let inbox = try? await store.mailbox(role: .inbox, accountKey: accountKey)
            else { return nil }

            return EmailSet.moveToInbox(
                ids: ids, inbox: inbox,
                leaving: try? await store.mailbox(role: .archive, accountKey: accountKey),
                accountID: accountID)

        case .trash:
            return EmailSet.trash(ids: ids, accountID: accountID)

        case .spam:
            guard let inbox = try? await store.mailbox(role: .inbox, accountKey: accountKey),
                let junk = try? await store.mailbox(role: .junk, accountKey: accountKey)
            else { return nil }

            return EmailSet.setSpam(
                true, ids: ids, inbox: inbox, junk: junk, accountID: accountID)

        case .setSeen(let isSeen):
            return EmailSet.setSeen(isSeen, ids: ids, accountID: accountID)

        case .setFlagged(let isFlagged):
            return EmailSet.setFlagged(isFlagged, ids: ids, accountID: accountID)

        case .setLabel(let isApplied, let labelID):
            guard let mailbox = try? await store.mailbox(labelID: labelID, accountKey: accountKey)
            else { return nil }

            return EmailSet.setLabel(
                isApplied, mailbox: mailbox, ids: ids, accountID: accountID)

        case .snooze:
            // Handled before this is reached: a snooze is a `Thread/set`.
            return nil
        }
    }

    private func send(_ request: EmailSet) async -> ActionDrain.Attempt {
        do {
            var builder = RequestBuilder(session: try await client.session())
            let call = builder.add(request)
            let results = try await client.send(builder)

            if let error = results.failure(of: call) { throw error }

            let result = try results.result(of: call)

            // A 200 is not success: `Email/set` reports per-object refusals in
            // `notUpdated`, and a refusal replayed is a loop that never ends.
            if let refused = result.notUpdated, refused.isEmpty == false {
                return .refused(String(describing: refused))
            }

            if let refused = result.notDestroyed, refused.isEmpty == false {
                return .refused(String(describing: refused))
            }

            return .sent
        } catch {
            return Self.attempt(after: error)
        }
    }

    private func send(_ request: ThreadSet) async -> ActionDrain.Attempt {
        do {
            var builder = RequestBuilder(session: try await client.session())
            let call = builder.add(request)
            let results = try await client.send(builder)

            if let error = results.failure(of: call) { throw error }

            if let refused = try results.result(of: call).notUpdated, refused.isEmpty == false {
                return .refused(String(describing: refused))
            }

            return .sent
        } catch {
            return Self.attempt(after: error)
        }
    }

    /// One place where an error becomes an outcome, so the two send paths
    /// cannot come to disagree about what counts as a refusal.
    nonisolated static func attempt(after error: any Error) -> ActionDrain.Attempt {
        ActionFailure.classify(error).isQueueWorthy
            ? .unreachable : .refused(String(describing: error))
    }

    /// Tries one account again, leaving the others alone.
    ///
    /// A per-account retry rather than a whole refresh: the other accounts are
    /// up to date, and re-syncing them to fix one is a request per mailbox
    /// against a server that is already having a bad day.
    public func retry(accountKey: String) async {
        guard let account = accounts.first(where: { $0.accountKey == accountKey }) else { return }

        degradedAccounts[accountKey] = nil
        failureStreak[accountKey] = nil

        await breaker.allowRetry()
        await syncMailboxes(for: account)

        mailboxes = (try? await allMailboxes()) ?? mailboxes

        _ = await delta.pull(accounts: [account])

        lastCheckedAt = .now
    }

    /// Loads whatever is cached, then refreshes from the server.
    ///
    /// Cache first and unconditionally: a home server is unreachable often
    /// enough that showing yesterday's mail immediately is the difference
    /// between an app that works on a train and one that doesn't.
    public func start(feed: FeedID) async {
        await loadCached()
        await refresh(feed: feed)
    }

    /// Re-reads whether any conversation carries a category.
    ///
    /// Cheap — one `fetchCount` with a limit of one — and worth doing whenever
    /// the inbox comes back on screen. The flag was previously set only on a
    /// cold load and after a page fetch, so anything that cleared it mid-session
    /// left the category tabs missing until the app was force-quit, which is
    /// exactly what was reported.
    public func refreshCategoryAvailability() async {
        hasCategories = (try? await store.hasCategorisedThreads()) ?? hasCategories
    }

    public func loadCached() async {
        do {
            accounts = try await store.accounts()
            mailboxes = try await allMailboxes()
            hasCategories = try await store.hasCategorisedThreads()
            publishSharedState()
        } catch {
            logger.error("Could not read the cache: \(error, privacy: .public)")
        }
    }

    /// Hands the widget and the Shortcuts intents a few numbers.
    ///
    /// Written on every cache load rather than on a timer, so it is refreshed
    /// by exactly the things that change it — a sync, a foreground, a delta
    /// pull — and never by anything else.
    private func publishSharedState() {
        // Unread across every inbox, which is what the app's own badge means
        // and therefore what a widget saying "unread" has to agree with.
        let unread =
            mailboxes
            .filter { $0.role == .inbox }
            .reduce(0) { $0 + $1.unreadThreads }

        let total =
            mailboxes
            .filter { $0.role == .inbox }
            .reduce(0) { $0 + $1.totalThreads }

        SharedMailStore.write(
            SharedMailState(unreadCount: unread, totalCount: total, updatedAt: .now))
    }

    /// Re-syncs structure and the first page of `feed`.
    public func refresh(feed: FeedID) async {
        status = .syncing
        defer { if case .syncing = status { status = .idle } }

        do {
            let session = try await client.verify()
            accounts = try await store.syncAccounts(session: session, serverID: serverID)
        } catch JMAPError.notAuthenticated {
            // Never retried and never backed off: a revoked app password stays
            // revoked, and hammering a home server over it helps nobody.
            status = .unauthenticated
            logger.error("Credential rejected by \(self.serverID, privacy: .public)")
            return
        } catch {
            status = .failed(message: describe(error))
            await breaker.recordFailure(error)
            logger.error("Session refresh failed: \(error, privacy: .public)")
            return
        }

        lastCheckedAt = .now
        await breaker.recordSuccess()
        isDeviceOffline = false

        // The server just answered, which is the evidence the drain waits for.
        // Sent before the delta pull for the same reason as in the background
        // path: the server's answer must not overwrite a change it has not
        // been told about yet.
        await drainQueuedActions()

        degradedAccounts = [:]
        // Rebuilt on next use: the mailbox ids a role maps to may have moved,
        // and a merge holds those in its pagers' filters.
        merges = [:]
        mergedAccounts = [:]

        // Structure first: a feed for a role cannot be built before the
        // mailbox ids that role maps to in each account are known.
        for account in accounts {
            await syncMailboxes(for: account)
        }

        mailboxes = (try? await allMailboxes()) ?? mailboxes

        // Objects before ordering: a message marked read elsewhere should be
        // right in the list the moment the list is built, rather than one
        // refresh later.
        _ = await delta.pull(accounts: accounts)

        await loadFirstPage(of: feed)

        // After the first page, not before: a fresh install has no threads at
        // all when this method starts, so asking any earlier would decide that
        // the server classifies nothing and hide the control until the next
        // launch.
        hasCategories = (try? await store.hasCategorisedThreads()) ?? hasCategories
    }

    // MARK: - Whole-list actions

    /// How many messages one "mark all as read" will touch per account.
    ///
    /// `Core/capabilities.maxObjectsInSet` is 500 on plMail, and a single
    /// `Email/set` carrying more than that is refused outright — so this is
    /// the cap, not a guess. A mailbox with more unread than this takes two
    /// presses, which is honest: the undo bar names the number it actually
    /// changed, and one enormous set that the server rejects would change
    /// nothing at all while looking like it had worked.
    public nonisolated static let bulkLimit = 500

    /// The unread mail one bulk action can reach, and what it cannot.
    ///
    /// The second number is the point. `maxObjectsInSet` is 500, so a mailbox
    /// with more unread than that cannot be cleared in one write — and the
    /// user who pressed "mark all as read" is entitled to know that some of it
    /// is still unread rather than discovering it from the badge.
    public struct UnreadSelection: Sendable {
        public var targets: [ActionTarget]
        /// Unread messages left over, summed across accounts. Zero when
        /// everything fitted.
        public var remaining: Int

        public init(targets: [ActionTarget], remaining: Int) {
            self.targets = targets
            self.remaining = remaining
        }
    }

    /// Every unread conversation in `feed`, ready for a bulk action.
    ///
    /// Asked of the server rather than read out of the store, because the
    /// store holds only what has been paged in. "Mark all as read" that
    /// silently meant "mark the first fifty as read" would leave a mailbox
    /// showing unread mail immediately after the user told it not to.
    ///
    /// One query and one get per account, all in a single POST. `Email/get`
    /// is asked only for `threadId`: the ids are what the action needs, and
    /// the thread grouping is what makes the count in the undo bar a count of
    /// conversations rather than of messages.
    public func unreadTargets(in feed: FeedID) async -> UnreadSelection {
        var calls:
            [(account: AccountSnapshot, query: CallHandle<EmailQuery>, get: CallHandle<EmailGet>)] =
                []
        var builder: RequestBuilder

        do {
            builder = RequestBuilder(session: try await client.session())
        } catch {
            logger.error("Could not reach the server to count unread: \(error, privacy: .public)")
            return UnreadSelection(targets: [], remaining: 0)
        }

        for account in accounts {
            guard let base = await pager(for: feed, account: account)?.baseFilter else {
                continue
            }

            let query = builder.add(
                EmailQuery(
                    accountID: account.accountID,
                    filter: .and([base, .notKeyword(.seen)]),
                    // Every unread *message*, not one per thread: a
                    // conversation with two unread replies has to have both
                    // patched, or it comes back unread the moment the list
                    // refreshes.
                    collapseThreads: false,
                    limit: Self.bulkLimit
                )
            )

            calls.append(
                (
                    account,
                    query,
                    builder.add(
                        EmailGet(
                            accountID: account.accountID,
                            ids: .reference(query.reference(path: "/ids")),
                            properties: ["id", "threadId"]
                        ))
                ))
        }

        guard calls.isEmpty == false else { return UnreadSelection(targets: [], remaining: 0) }

        let results: MethodResults

        do {
            results = try await client.send(builder)
        } catch {
            logger.error("Could not list unread mail: \(error, privacy: .public)")
            return UnreadSelection(targets: [], remaining: 0)
        }

        var targets: [ActionTarget] = []
        var remaining = 0

        for call in calls {
            // Per account, like everything else here: one mailbox refusing
            // must not stop the others being marked read.
            guard let list = try? results.result(of: call.get).list else { continue }

            // What the mailbox holds against what one write can carry. The
            // caller has to be able to say so: "mark all as read" that marks
            // five hundred of six hundred and reports nothing is the app
            // quietly doing less than it was told.
            remaining += Self.remainingBeyondLimit(
                total: try? results.result(of: call.query).total, fetched: list.count)

            var byThread: [String: [EmailID]] = [:]

            for email in list {
                byThread[email.threadID?.rawValue ?? email.id.rawValue, default: []]
                    .append(email.id)
            }

            for (threadID, emailIDs) in byThread {
                targets.append(
                    ActionTarget(
                        threadID: threadID,
                        accountKey: call.account.accountKey,
                        accountID: call.account.accountID,
                        emailIDs: emailIDs
                    ))
            }
        }

        return UnreadSelection(targets: targets, remaining: remaining)
    }

    /// How many unread messages one press will leave behind.
    ///
    /// `total` is what the server says matches the filter; `fetched` is what
    /// came back under ``bulkLimit``. A server that declines to count answers
    /// nil, and the honest reading of that is "nothing known to remain" rather
    /// than a guess — claiming leftovers that may not exist would send the
    /// user pressing a button that does nothing.
    nonisolated static func remainingBeyondLimit(total: Int?, fetched: Int) -> Int {
        guard let total else { return 0 }

        return max(0, total - fetched)
    }

    /// Re-reads mailbox structure, and with it the server's unread counts.
    ///
    /// Called after an action that changes how many unread messages a mailbox
    /// holds. Those counts come from `Mailbox/get` and nothing local
    /// recomputes them, so without this the sidebar goes on claiming five
    /// unread in a list the user has just emptied — the app disagreeing with
    /// itself on the same screen.
    public func refreshStructure() async {
        for account in accounts {
            await syncMailboxes(for: account)
        }

        mailboxes = (try? await allMailboxes()) ?? mailboxes
    }

    // MARK: - Structure

    private func syncMailboxes(for account: AccountSnapshot) async {
        do {
            var builder = RequestBuilder(session: try await client.session())
            let get = builder.add(MailboxGet(accountID: account.accountID))
            // Identities in the same round trip. They used to be fetched only
            // when a composer opened, which had two consequences: the composer
            // waited on a request before it could show who it was sending as,
            // and an account with no name of its own stayed called "Mailbox
            // 1119" in the list until you happened to write a message. Both
            // are fixed by asking here, where the structure is already being
            // read, for no extra round trip.
            let identities = builder.add(IdentityGet(accountID: account.accountID))
            let results = try await client.send(builder)
            let result = try results.result(of: get)

            try await store.replaceMailboxes(
                result.list,
                accountKey: account.accountKey,
                state: result.state
            )

            // Not fatal. A server that refuses `Identity/get` still has a
            // perfectly usable mailbox, and failing the whole structure sync
            // over the sender list would be out of proportion.
            if let identities = try? results.result(of: identities).list {
                try? await store.replaceIdentities(identities, accountKey: account.accountKey)
            }

            try await store.recordSyncSuccess(accountKey: account.accountKey)

            // A good answer clears both the banner and the streak that would
            // have raised it.
            failureStreak[account.accountKey] = nil
            degradedAccounts[account.accountKey] = nil
        } catch {
            await degrade(account, error: error)
        }
    }

    // MARK: - Feed paging

    /// Brings `feed` up to date and makes sure it has a first screenful.
    public func loadFirstPage(of feed: FeedID) async {
        let merge = await merge(for: feed)

        await merge.refreshHead()
        await merge.loadMore()

        degradedAccounts = await merge.failures
    }

    /// Runs a search, replacing any previous results for the same query.
    ///
    /// Rebuilt rather than refreshed: a search feed's rows are answers to a
    /// question, and re-asking should not splice new answers on top of stale
    /// ones from a query that has since changed.
    public func search(feed: FeedID) async {
        for account in accounts {
            try? await store.resetFeed(feedID: feed.rawValue, accountKey: account.accountKey)
        }

        merges[feed] = nil
        mergedAccounts[feed] = nil

        status = .syncing
        defer { if case .syncing = status { status = .idle } }

        let merge = await merge(for: feed)
        await merge.loadMore()

        degradedAccounts = await merge.failures

        await loadSnippets(for: feed)
    }

    /// Asks the server which part of each result actually matched.
    ///
    /// A separate round trip on purpose: `SearchSnippet/get` needs the ids the
    /// query returned, and there is no back-reference from a query to a
    /// snippet call. It runs after the rows are already on screen, so results
    /// appear at query speed and sharpen a moment later rather than waiting.
    ///
    /// Failure is silent. A snippet is an improvement on the preview the row
    /// already has; a server that does not implement the method — it is
    /// optional in RFC 8621 — should cost nothing but the generic text.
    private func loadSnippets(for feed: FeedID) async {
        guard case .searchResults(let raw) = feed else { return }

        let parsed = SearchQuery.parse(raw)

        let rows = (try? await store.feedRows(feedID: feed.rawValue)) ?? []

        for account in accounts {
            let ids = rows.filter { $0.accountKey == account.accountKey }.map(\.emailID)

            guard ids.isEmpty == false else { continue }

            let accountMailboxes = mailboxes.filter { $0.accountKey == account.accountKey }

            // The same filter the query ran with, built the same way — through
            // the scope, so a `label:` narrowing is honoured here too. A
            // different filter would highlight terms the results were never
            // matched on.
            let scope = SearchQueryCompiler.scope(for: parsed, mailboxes: accountMailboxes)
            let filter = SearchQueryCompiler.filter(for: parsed, scope: scope)

            // `SearchSnippet/get` refuses more than 500 ids outright, and this
            // treats any failure as "no highlighting". Without the batching, a
            // search that paged past 500 results lost highlighting on **every**
            // row in **every** account at once, silently.
            for batch in SearchSnippetBatch.batches(ids) {
                do {
                    var builder = RequestBuilder(session: try await client.session())
                    let call = builder.add(
                        SearchSnippetGet(
                            accountID: account.accountID,
                            filter: filter,
                            emailIDs: batch.map { EmailID($0) }
                        )
                    )

                    let results = try await client.send(builder)

                    for snippet in try results.result(of: call).list {
                        guard snippet.preview != nil || snippet.subject != nil else { continue }

                        highlights["\(account.accountKey)#\(snippet.emailID.rawValue)"] =
                            SearchHighlight(subject: snippet.subject, body: snippet.preview)
                    }
                } catch {
                    logger.debug("No snippets for \(account.accountKey, privacy: .public)")
                }
            }
        }
    }

    /// Drops a search's stored rows.
    ///
    /// Called when a search is abandoned: one materialised feed per query ever
    /// typed would grow without bound, and none of them is worth keeping.
    public func discardSearch(feed: FeedID) async {
        guard case .searchResults = feed else { return }

        highlights.removeAll()

        for account in accounts {
            try? await store.resetFeed(feedID: feed.rawValue, accountKey: account.accountKey)
        }

        merges[feed] = nil
        mergedAccounts[feed] = nil
    }

    /// Extends `feed` by one screenful, interleaved across every account.
    public func loadMore(of feed: FeedID) async {
        let merge = await merge(for: feed)

        await merge.loadMore()

        degradedAccounts = await merge.failures
    }

    /// The merge for a feed, built once and kept.
    ///
    /// Kept rather than rebuilt per call because it holds each account's
    /// buffer: discarding that between scrolls would re-fetch a page per
    /// account every time the list reached its end.
    private func merge(for feed: FeedID) async -> UnifiedFeed {
        if let existing = merges[feed], mergedAccounts[feed] == accountKeys {
            return existing
        }

        let merge = UnifiedFeed(feedID: feed, client: client, store: store)
        var pagers: [AccountPager] = []

        for account in accounts {
            if let pager = await pager(for: feed, account: account) {
                pagers.append(pager)
            }
        }

        await merge.prepare(pagers: pagers)

        merges[feed] = merge
        mergedAccounts[feed] = accountKeys

        return merge
    }

    private var accountKeys: Set<String> { Set(accounts.map(\.accountKey)) }

    /// Builds the filter that selects `feed` within one account.
    ///
    /// Returns nil when the account has no mailbox for that role — a Gmail
    /// account has no Archive binding until one exists, and skipping it is
    /// right where erroring would take down the whole list.
    private func pager(for feed: FeedID, account: AccountSnapshot) async -> AccountPager? {
        let filter: EmailFilter?

        switch feed {
        case .unified(let role):
            guard
                let mailboxID = try? await store.mailbox(
                    role: role, accountKey: account.accountKey)
            else { return nil }

            filter = .inMailbox(mailboxID)

        case .unifiedLabel(let labelID):
            let matching = mailboxes.first {
                $0.accountKey == account.accountKey && $0.labelID == labelID
            }

            guard let matching else { return nil }

            filter = .inMailbox(matching.mailboxID)

        case .category(let category):
            guard
                let inbox = try? await store.mailbox(
                    role: .inbox, accountKey: account.accountKey)
            else { return nil }

            // The inbox binding is part of the filter, not context around it.
            // A conversation keeps its category after it is moved to Trash, so
            // `threadCategory` alone would put the bin's promotions on a list
            // that claims to be a slice of the inbox.
            //
            // Server-side, never by sieving a fetched page: `Email/query`
            // windows by limit, so filtering locally would draw four rows under
            // a list that had already reached its end.
            filter = .and([.inMailbox(inbox), .threadCategory(category)])

        case .mailbox(let accountKey, let mailboxID):
            guard accountKey == account.accountKey else { return nil }

            filter = .inMailbox(mailboxID)

        case .searchResults(let raw):
            let parsed = SearchQuery.parse(raw)
            let accountMailboxes = mailboxes.filter { $0.accountKey == account.accountKey }

            // Through the scope, not the single-mailbox entry point: `in:` and
            // `label:` both compile to `inMailbox` and can appear together, and
            // the legacy path refuses a query carrying `label:` outright rather
            // than compiling one that quietly drops it. Until this asked for a
            // scope, `label:` returned nothing at all.
            let scope = SearchQueryCompiler.scope(for: parsed, mailboxes: accountMailboxes)

            // An account with no mailbox for the requested role or label cannot
            // answer this query, and including it unfiltered would return its
            // whole mailbox as "results".
            guard scope.canSearch else { return nil }

            filter = SearchQueryCompiler.filter(for: parsed, scope: scope)

            // A query that narrows nothing would page the entire account.
            guard filter != nil else { return nil }
        }

        return AccountPager(
            accountKey: account.accountKey,
            accountID: account.accountID,
            baseFilter: filter
        )
    }

    // MARK: - Failure

    /// How many consecutive failures an account has had.
    ///
    /// Reset by any success. See ``degrade(_:error:)`` for why a single failure
    /// is not enough to say anything to the user.
    private var failureStreak: [String: Int] = [:]

    /// How many failures in a row before the interface calls a server
    /// unreachable.
    ///
    /// **One is far too few.** A self-hosted server on a LAN, a Tailscale node
    /// or a NAS drops the occasional request — a Wi-Fi roam, a PHP worker
    /// recycling, a laptop lid — and the app now makes several times as many
    /// requests as it used to because it prefetches message bodies. Reporting
    /// the first of those as "plMail could not reach <host>" cries wolf over a
    /// server that is up and answering, and an owner who has learned to ignore
    /// the banner will ignore the real outage too. Two in a row over a cache
    /// that is still perfectly readable is the point at which it is worth
    /// saying something.
    private static let failuresBeforeDegrading = 2

    private func degrade(_ account: AccountSnapshot, error: any Error) async {
        let message = describe(error)
        let streak = (failureStreak[account.accountKey] ?? 0) + 1

        failureStreak[account.accountKey] = streak

        // Recorded from the first failure — the diagnostics screen and the
        // accounts list want the truth — but not *said* until it repeats.
        try? await store.recordSyncFailure(message, accountKey: account.accountKey)
        logger.error(
            "\(account.name, privacy: .public) failed \(streak, privacy: .public)x: \(error, privacy: .public)"
        )

        guard streak >= Self.failuresBeforeDegrading else { return }

        degradedAccounts[account.accountKey] = message
    }

    private func allMailboxes() async throws -> [MailboxSnapshot] {
        var all: [MailboxSnapshot] = []

        for account in accounts {
            all += try await store.mailboxes(accountKey: account.accountKey)
        }

        return all
    }

    /// Messages name the cause and the host. Users self-host: when the server
    /// is down they are the one who has to go and fix it, and the hostname is
    /// genuinely the useful part.
    private func describe(_ error: any Error) -> String {
        guard let error = error as? JMAPError else { return error.localizedDescription }

        switch error {
        case .notAuthenticated:
            return String(
                localized: "Your app password was revoked or is no longer valid.", bundle: .module)
        case .unreachable(let host, _):
            return String(localized: "Can't reach \(host).", bundle: .module)
        case .untrustedCertificate(let host, _):
            return "\(host) presented a certificate that no longer matches the one you trusted."
        case .methodFailed(let type, let description, _):
            // Raw JMAP error types are for the log, never for a person.
            logger.error("Method error \(type.rawValue, privacy: .public): \(description ?? "")")
            return String(localized: "The server couldn't complete that request.", bundle: .module)
        default:
            logger.error("Unexpected: \(error, privacy: .public)")
            return String(
                localized: "Something went wrong talking to \(connection.host).", bundle: .module)
        }
    }
}

/// Where in a message a search actually matched.
///
/// Two fields rather than one string, because the two are drawn in different
/// places: `SearchSnippet/get` returns a highlighted subject *and* a
/// highlighted body extract, and collapsing them with `preview ?? subject`
/// puts a subject match in the row's body-snippet slot — the same words twice
/// on one row, with the sentence they were found in nowhere to be seen.
public struct SearchHighlight: Hashable, Sendable {
    /// The subject with matches marked, when the subject is what matched.
    public var subject: String?
    /// An extract from the body with matches marked.
    public var body: String?

    public init(subject: String? = nil, body: String? = nil) {
        self.subject = subject
        self.body = body
    }
}
