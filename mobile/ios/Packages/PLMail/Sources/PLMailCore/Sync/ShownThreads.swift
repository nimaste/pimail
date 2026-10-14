import Foundation
import JMAPKit
import OSLog

/// Tells the server which conversations have actually been put in front of the
/// user, so their New markers can be retired.
///
/// **This is the feature, not a courtesy.** `Thread.isNew` is retired only by a
/// client that draws the row, and nothing else in the system can do it. An iOS
/// app that shows the badge and never reports back leaves the web UI and
/// Android badging mail this user has already read — permanently, until the
/// 24-hour window lapses — so the reporting half is what makes the marker mean
/// anything at all.
///
/// Three properties are load-bearing, and each of them exists because of a
/// specific failure:
///
/// - **Batched.** A list reports one id per row as rows appear, several times a
///   second while somebody scrolls. Sent one at a time that is a request per
///   row against what is frequently a Raspberry Pi with one PHP worker pool.
///   Ids accumulate and one call carries a whole page.
/// - **Nothing waits on it.** ``report(threadID:accountKey:accountID:)`` returns
///   immediately. A retirement is bookkeeping; blocking a scroll on it would
///   trade the feature for the app.
/// - **Failure is cheap and deliberately not retried hard.** The row will be
///   drawn again, and the marker is only spent locally once the server has
///   actually accepted it — see ``SyncStore/clearNewMarkers(threadIDs:accountKey:)``.
///
/// Retirement is *not* a `Thread` state change server-side, so it pushes
/// nothing to the user's other devices; the next ordinary `Thread/get` carries
/// the new value.
public actor ShownThreads {
    /// How long ids collect before a call goes out.
    ///
    /// Long enough that flinging through a page is one request rather than
    /// fifty, short enough that a person who reads one row and switches to the
    /// browser finds it already retired. Not tunable per call site: two
    /// debounce windows would mean two answers to how hard this client leans on
    /// somebody's home server.
    static let debounce = Duration.milliseconds(750)

    /// `ThreadSetMethod::MAX_OBJECTS`. A longer call is refused whole with
    /// `requestTooLarge`, so a backlog is chunked here rather than discovered on
    /// the wire.
    static let batchLimit = ThreadSet.maxObjects

    /// Ids waiting to be sent, per account. A set, so a row redrawn twice
    /// inside one window is still one id.
    private var pending: [String: Set<String>] = [:]
    /// The account id to address each account key by, learned from the caller
    /// rather than looked up: the list already holds it, and a store read per
    /// reported row is exactly the per-row cost this type exists to avoid.
    private var accountIDs: [String: AccountID] = [:]
    /// Conversations this process has already had accepted.
    ///
    /// **The guard that makes a row drawn many times reported once.** A list row
    /// appears every time it is scrolled back onto screen, and the server's own
    /// idempotence does not make those free — they are still requests. Cleared
    /// for an id whose report failed, so a retry can happen the next time the
    /// row is drawn.
    private var reported: Set<String> = []
    private var flush: Task<Void, Never>?

    private let client: JMAPClient
    private let store: SyncStore
    private let logger = Logger(subsystem: "de.plmail", category: "shown")

    public init(client: JMAPClient, store: SyncStore) {
        self.client = client
        self.store = store
    }

    /// Notes that one conversation's row has been drawn.
    ///
    /// Call this **only for a genuine display**. A page arriving from the
    /// pager, a background delta pull, a notification and the body prefetcher
    /// all put conversations on the device without anybody seeing them, and
    /// none of those is a display — reporting them would spend markers for mail
    /// the user has never laid eyes on, in every client they own.
    public func report(threadID: String, accountKey: String, accountID: AccountID) {
        let key = "\(accountKey)#\(threadID)"

        guard reported.contains(key) == false else { return }

        reported.insert(key)
        accountIDs[accountKey] = accountID
        pending[accountKey, default: []].insert(threadID)

        schedule()
    }

    /// Arms the debounce, unless a flush is already armed.
    ///
    /// A flush already in flight simply takes the newer ids with it — the queue
    /// is read when the call is built, not when it was scheduled — so this
    /// never stacks up one task per reported row.
    private func schedule() {
        guard flush == nil else { return }

        flush = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)

            await self?.send()
        }
    }

    /// Sends everything waiting, and re-arms if more arrived meanwhile.
    private func send() async {
        flush = nil

        let batch = pending
        pending = [:]

        guard batch.isEmpty == false else { return }

        for (accountKey, threadIDs) in batch {
            guard let accountID = accountIDs[accountKey] else { continue }

            // Chunked at the server's own ceiling. A user who has scrolled
            // through six hundred conversations while offline comes back with a
            // backlog longer than one call may carry, and the server refuses an
            // over-long call whole rather than trimming it.
            for chunk in stride(from: 0, to: threadIDs.count, by: Self.batchLimit) {
                let slice = Array(
                    Array(threadIDs)[chunk..<min(chunk + Self.batchLimit, threadIDs.count)])

                await retire(slice, accountKey: accountKey, accountID: accountID)
            }
        }
    }

    /// One `Thread/set`, and the local clear that follows a success.
    ///
    /// The local column is cleared **only** when the server accepted the write.
    /// Clearing optimistically would lose the badge on this device while the
    /// server still held the marker, leaving nothing on screen to retire it and
    /// the browser badged forever.
    private func retire(_ threadIDs: [String], accountKey: String, accountID: AccountID) async {
        do {
            var builder = RequestBuilder(session: try await client.session())
            let call = builder.add(
                ThreadSet.shown(threadIDs.map { ThreadID($0) }, accountID: accountID))

            let results = try await client.send(builder)

            if let failure = results.failure(of: call) { throw failure }

            _ = try results.result(of: call)

            try await store.clearNewMarkers(threadIDs: threadIDs, accountKey: accountKey)
        } catch {
            // Deliberately no retry loop and no backoff timer. The row will be
            // drawn again — that is the whole recovery path — and a client that
            // hammered a home server to retire a badge would be spending the
            // user's only mail server on cosmetics.
            for threadID in threadIDs { reported.remove("\(accountKey)#\(threadID)") }

            logger.notice(
                "Could not report \(threadIDs.count) displays for \(accountKey, privacy: .public): \(error, privacy: .public)"
            )
        }
    }

    /// Sends whatever is waiting without waiting for the debounce.
    ///
    /// For the moment a list goes away — a mailbox change, the app going to the
    /// background — where the alternative is a report that is dropped on the
    /// floor because the scene was torn down 300ms into a 750ms window.
    public func flushNow() async {
        flush?.cancel()
        flush = nil

        await send()
    }

    /// How many ids are waiting. Test seam only: the batching guarantee is the
    /// thing worth asserting on, and it is invisible from the outside otherwise.
    var pendingCount: Int { pending.values.reduce(0) { $0 + $1.count } }
}
