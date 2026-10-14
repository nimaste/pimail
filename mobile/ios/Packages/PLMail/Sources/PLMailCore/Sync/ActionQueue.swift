import Foundation
import JMAPKit
import OSLog

/// Mail actions taken while the server could not be reached.
///
/// **Deliberately not in the SwiftData store**, for the reason `Compose/Outbox`
/// is not: the store's governing rule is that everything in it is
/// reconstructible from the server, which is what licenses `MailStack` deleting
/// and rebuilding it on any open failure. A conversation archived on a train is
/// the one fact about the mailbox that exists nowhere else until it is sent, so
/// a schema change would silently throw away work the user had already watched
/// happen. It lives in Application Support beside the outbox — backed up, and
/// never reclaimed the way `Caches` may be.
///
/// One JSON file per mutation rather than one array file: a drain rewriting the
/// whole queue to remove its head is a window in which a crash loses everything
/// behind it.
///
/// Enqueued by ``MailActions`` and emptied by ``ActionDrain``; what is
/// queue-worthy is decided by ``ActionFailure``.
public actor ActionQueue {
    /// One queue per server, shared by everyone who touches it.
    ///
    /// Two `ActionQueue` instances over the same directory would each believe
    /// they owned the drain, and the same file would be read and sent by both
    /// — an archive replayed after the user had already undone it. The two
    /// halves are constructed in different places (``MailActions`` by the view
    /// layer, ``ActionDrain`` by ``MailSyncService``) and neither can hand the
    /// other an instance, so the identity has to live here.
    @MainActor private static var instances: [String: ActionQueue] = [:]

    /// The queue for the server this app is signed into.
    ///
    /// The app connects to exactly one server at a time — there is one
    /// `ServerConnection` and one ``MailSyncService`` — but ``MailActions`` is
    /// built by a view that is handed a client and a store and no server id.
    /// Rather than thread one through a view initialiser this module does not
    /// own, the sync service claims the current queue as it is created, which
    /// it always is before any list can exist.
    @MainActor public private(set) static var current: ActionQueue?

    /// The queue for `serverID`, created once.
    ///
    /// Also makes it ``current``: signing into a different server must not
    /// leave actions aimed at the previous one being drained against this one,
    /// where their ids resolve to unrelated conversations rather than to
    /// nothing.
    @MainActor
    public static func shared(serverID: String) -> ActionQueue {
        let queue = instances[serverID] ?? ActionQueue(serverID: serverID)
        instances[serverID] = queue
        current = queue

        return queue
    }

    /// Internal rather than private so a test can plant a file in the shape an
    /// older build wrote — the only way to check the format stayed readable.
    let directory: URL
    private let logger = Logger(subsystem: "de.plmail", category: "actions")

    /// Handed out in strictly increasing order and never reused.
    ///
    /// Order within an account is not incidental: star-then-unstar and
    /// archive-then-move do not commute, so replaying them by wall clock alone
    /// would occasionally invert a pair queued in the same millisecond and
    /// leave the server in a state the user never asked for. Seeded from the
    /// highest sequence already on disk so a relaunch mid-queue continues
    /// rather than restarts.
    private var nextSequence: Int?

    /// - Parameter serverID: Scopes the queue to one server, so signing into a
    ///   different one cannot inherit actions aimed at the previous account's
    ///   ids — which resolve to unrelated conversations rather than to nothing.
    public init(serverID: String) {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL.temporaryDirectory

        directory =
            base
            .appending(path: "plmail-actions", directoryHint: .isDirectory)
            .appending(path: Outbox.slug(serverID), directoryHint: .isDirectory)

        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
    }

    /// Everything waiting, in the order it must be sent.
    public func pending() -> [PendingMutation] {
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)
        else { return [] }

        return
            entries
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> PendingMutation? in
                guard let data = try? Data(contentsOf: url) else { return nil }

                return try? JSONDecoder().decode(PendingMutation.self, from: data)
            }
            .sorted { $0.sequence < $1.sequence }
    }

    public func count() -> Int {
        pending().count
    }

    /// The conversations this queue has an opinion about.
    ///
    /// Read before anything rewrites feed rows from the server: a sync that
    /// does not consult it puts back on screen the conversation the user
    /// archived a minute ago, and the gesture appears to have been ignored.
    public func pendingTargets() -> Set<String> {
        Set(pending().map(\.targetKey))
    }

    /// Files a mutation for later, at the end of the queue.
    @discardableResult
    public func enqueue(_ mutation: PendingMutation) throws -> PendingMutation {
        var mutation = mutation
        mutation.sequence = takeSequence()

        try write(mutation)

        return mutation
    }

    /// Rewrites a mutation in place, keeping its position.
    ///
    /// Used to record an attempt. Removing and re-adding would send a
    /// repeatedly failing item to the back of the queue, which reorders
    /// everything behind it for no reason the user could predict.
    public func update(_ mutation: PendingMutation) {
        try? write(mutation)
    }

    public func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: file(for: id))
    }

    /// Drops everything queued for one account.
    ///
    /// An account that has been disconnected can never accept its backlog, and
    /// retrying it forever would stall every account behind it — the drain
    /// stops at the first failure by design.
    public func removeAll(forAccountKey accountKey: String) {
        for mutation in pending() where mutation.accountKey == accountKey {
            remove(mutation.id)
        }
    }

    // MARK: - Storage

    private func write(_ mutation: PendingMutation) throws {
        try JSONEncoder().encode(mutation).write(to: file(for: mutation.id), options: .atomic)
    }

    private func file(for id: UUID) -> URL {
        directory.appending(path: "\(id.uuidString).json")
    }

    private func takeSequence() -> Int {
        let next = nextSequence ?? ((pending().last?.sequence ?? 0) + 1)
        nextSequence = next + 1

        return next
    }
}

/// One mail action, persisted until the server has accepted it.
///
/// **Queue a transport failure, never a refusal.** `JMAPError.unreachable`, a
/// `URLError` and a request that never got an answer mean this device is right
/// and the server has not caught up; `notUpdated`, `forbidden`,
/// `accountReadOnly` and `invalidProperties` mean the server has considered the
/// change and said no. Replaying a refusal loops forever, and the row has to go
/// back on screen instead.
public struct PendingMutation: Identifiable, Hashable, Sendable, Codable {
    /// What to do. The payload lives in the case rather than beside it, so
    /// "which action" and "with what" cannot disagree — a `setLabel` with no
    /// label is unrepresentable.
    public enum Kind: Hashable, Sendable, Codable {
        case archive
        case moveToInbox
        case trash
        case spam
        case setSeen(Bool)
        case setFlagged(Bool)
        /// Carries the **user-scoped** ``JMAPKit/LabelID``, not the
        /// per-account `MailboxID` the wire call needs.
        ///
        /// A binding id is only valid against the account it came from and can
        /// be recreated with a different number, so a queue holding one may
        /// apply the wrong label after the label is deleted and remade. Resolve
        /// it to a binding at drain time; a label that no longer resolves is
        /// dropped and counted as sent, because a queue that cannot empty
        /// blocks every action behind it.
        case setLabel(isApplied: Bool, labelID: LabelID)
        /// Nil releases a snoozed conversation.
        case snooze(until: Date?)
    }

    public var id = UUID()
    /// Position in the queue. Assigned by ``ActionQueue/enqueue(_:)``; the
    /// value carried by an unqueued instance is meaningless.
    public var sequence: Int = 0

    public var accountKey: String
    public var accountID: AccountID
    /// A whole conversation, matching ``ActionTarget``: archiving one reply and
    /// leaving the rest is not something anyone means.
    public var threadID: String
    /// The messages the wire call names. Stable ids, unlike a label binding, so
    /// these are safe to hold across a relaunch.
    public var emailIDs: [EmailID]
    public var kind: Kind

    public var queuedAt = Date.now
    public var attempts = 0
    public var lastFailure: String?

    /// Scoped by account, because thread ids are unique only within one.
    /// Matches ``ActionTarget/id`` so a feed projection can compare the two
    /// without a conversion step that could drift.
    public var targetKey: String { "\(accountKey)#\(threadID)" }

    public init(
        accountKey: String,
        accountID: AccountID,
        threadID: String,
        emailIDs: [EmailID],
        kind: Kind
    ) {
        self.accountKey = accountKey
        self.accountID = accountID
        self.threadID = threadID
        self.emailIDs = emailIDs
        self.kind = kind
    }
}
