import Foundation
import JMAPKit
import OSLog
import Observation

/// Loads one conversation and keeps its read state honest.
@MainActor
@Observable
public final class ThreadLoader {
    public private(set) var messages: [MessageSnapshot] = []
    /// When this conversation is due back, if it is snoozed. Read from the
    /// store rather than tracked here, so the reader agrees with the row that
    /// opened it.
    public private(set) var snoozedUntil: Date?
    /// This account's own addresses, so "reply all" can tell whether there is
    /// anyone else to include — replying to everyone on a message addressed
    /// only to you is the same as replying.
    public private(set) var ownAddresses: [String] = []
    /// The labels this conversation carries, for the reader's header. Whole
    /// snapshots rather than names, because a role label wants the colour its
    /// role has everywhere else and a custom one wants its hashed colour —
    /// which the name alone cannot tell them apart by.
    public private(set) var labels: [MailboxSnapshot] = []
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?

    private let threadID: String
    private let accountKey: String
    private let accountID: AccountID
    private let client: JMAPClient
    private let store: SyncStore
    private let logger = Logger(subsystem: "de.plmail", category: "reader")

    public init(
        threadID: String,
        accountKey: String,
        accountID: AccountID,
        client: JMAPClient,
        store: SyncStore
    ) {
        self.threadID = threadID
        self.accountKey = accountKey
        self.accountID = accountID
        self.client = client
        self.store = store
    }

    /// Shows what is cached, then fetches the rest.
    public func load() async {
        await readCache()

        isLoading = true
        defer { isLoading = false }

        do {
            try await fetch()
            await readCache()
            errorMessage = nil
        } catch {
            // Cached messages stay on screen: a thread you have already read
            // should still be readable on a train.
            errorMessage = describe(error)
            logger.error("Thread \(self.threadID, privacy: .public): \(error, privacy: .public)")
        }
    }

    private func readCache() async {
        // Now that the whole thread is here, the row's guess at who is in it
        // can be replaced with the answer.
        try? await store.refreshParticipants(threadID: threadID, accountKey: accountKey)

        messages = (try? await store.messages(threadID: threadID, accountKey: accountKey)) ?? []
        snoozedUntil = try? await store.snoozedUntil(
            threadID: threadID, accountKey: accountKey)
        ownAddresses = ((try? await store.identities(accountKey: accountKey)) ?? [])
            .map(\.email)

        let carried =
            (try? await store.mailboxIDs(threadID: threadID, accountKey: accountKey)) ?? []
        let mailboxes = (try? await store.mailboxes(accountKey: accountKey)) ?? []

        labels =
            mailboxes
            .filter { carried.contains($0.mailboxID.rawValue) }
            // Roles first, then custom labels alphabetically: where a
            // conversation lives is a more useful first word than what it is
            // tagged with.
            .sorted {
                ($0.role == nil ? 1 : 0, $0.name.lowercased())
                    < ($1.role == nil ? 1 : 0, $1.name.lowercased())
            }
    }

    /// One round trip: the thread's message ids, then those messages with
    /// their bodies, paired by back-reference.
    private func fetch() async throws {
        let session = try await client.session()
        var builder = RequestBuilder(session: session)

        let thread = builder.add(
            ThreadGet(accountID: accountID, ids: .value([ThreadID(threadID)])))

        let emails = builder.add(
            EmailGet(
                accountID: accountID,
                ids: .reference(thread.reference(path: "/list/*/emailIds")),
                properties: EmailGet.readerProperties,
                fetchTextBodyValues: true,
                fetchHTMLBodyValues: true,
                // Enough for any mail a person will read; a message larger
                // than this is a document, and truncating beats spending a
                // home uplink's whole budget on one newsletter.
                maxBodyValueBytes: 1_000_000
            )
        )

        let results = try await client.send(builder)
        let threads = try results.result(of: thread).list
        let list = try results.result(of: emails).list

        try await store.upsert(
            emails: list, threads: threads, accountKey: accountKey, emailState: nil)
        try await store.storeReaderContent(list, accountKey: accountKey)
    }

    // MARK: - Read state

    /// Marks the messages the reader says have been displayed read.
    ///
    /// Per message, not per thread. The previous version collected every
    /// unread message in the conversation and marked the lot the moment the
    /// thread appeared, so opening a forty-message thread to read the newest
    /// reply cleared the unread state of thirty-nine messages nobody saw —
    /// on this device and on every other one, irreversibly from the user's
    /// side. ``ReadReceipts`` decides which ids arrive here; this method only
    /// writes them.
    ///
    /// Applied locally first so the card updates immediately, then sent; the
    /// server routes it through the same propagator the web UI uses, so it
    /// reaches Gmail/IMAP/Graph identically.
    ///
    /// - Parameter emailIDs: Already filtered to unread, already de-duplicated.
    ///   A caller passing an empty list costs nothing, which is what lets the
    ///   reader call this on every scroll without thinking about it.
    public func markRead(emailIDs: [String]) async {
        guard emailIDs.isEmpty == false else { return }

        try? await store.setSeen(true, emailIDs: emailIDs, accountKey: accountKey)
        await readCache()

        do {
            var builder = RequestBuilder(session: try await client.session())
            builder.add(
                EmailSetKeywords(
                    accountID: accountID,
                    ids: emailIDs.map { EmailID(rawValue: $0) },
                    isSeen: true
                )
            )

            _ = try await client.send(builder)
        } catch {
            // Left applied locally rather than reverted: the next sync's
            // Email/changes will correct it either way, and flipping the row
            // back under the reader's eyes is worse than being briefly ahead
            // of the server.
            logger.error("Marking read failed: \(error, privacy: .public)")
        }
    }

    private func describe(_ error: any Error) -> String {
        guard let error = error as? JMAPError else { return error.localizedDescription }

        return switch error {
        case .notAuthenticated: "Your app password is no longer valid."
        case .unreachable(let host, _): "Can't reach \(host)."
        default: "This conversation couldn't be loaded."
        }
    }
}
