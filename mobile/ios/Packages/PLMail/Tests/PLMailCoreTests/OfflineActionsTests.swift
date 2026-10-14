import Foundation
import JMAPKit
import JMAPTestSupport
import Testing

@testable import PLMailCore

/// What happens to a gesture when the server is not there.
///
/// Before this, `MailActions` rolled the optimistic change back and discarded
/// it on *any* send failure: the user archived a conversation on a train,
/// watched the row leave, and watched it come back with "couldn't reach the
/// server". The distinction that fixes it is the one worth testing — a server
/// that refused is not a server that never answered.
@Suite("Offline actions")
@MainActor
struct OfflineActionsTests {
    private let accountID = AccountID("1")

    /// A queue per test, on its own directory: this is deliberately real files,
    /// because surviving the process is the whole point of the type.
    private func makeQueue() -> ActionQueue {
        ActionQueue(serverID: "actions-\(UUID().uuidString)")
    }

    private func makeStore() async throws -> SyncStore {
        let store = SyncStore(modelContainer: MailStack.makeContainer(inMemory: true))

        var inbox = Mailbox(id: MailboxID("70"))
        inbox.name = "Inbox"
        inbox.role = .inbox

        var archive = Mailbox(id: MailboxID("71"))
        archive.name = "Archive"
        archive.role = .archive

        try await store.replaceMailboxes(
            [inbox, archive], accountKey: "srv/1", state: StateToken(rawValue: "1"))

        var email = Email(id: EmailID("e1"))
        email.threadID = ThreadID("t1")
        email.receivedAt = UTCDate(Date(timeIntervalSince1970: 1_700_000_000))
        email.mailboxIDs = JMAPIDSet([MailboxID("70")])

        try await store.upsert(
            emails: [email],
            threads: [MailThread(id: ThreadID("t1"), emailIDs: [EmailID("e1")])],
            accountKey: "srv/1",
            emailState: nil)

        try await store.appendFeedRows(
            [
                FeedRow(
                    threadID: "t1", emailID: "e1",
                    sortDate: Date(timeIntervalSince1970: 1_700_000_000))
            ],
            feedID: FeedID.unified(.inbox).rawValue,
            accountKey: "srv/1",
            cursor: FeedCursorSnapshot()
        )

        return store
    }

    private var target: ActionTarget {
        ActionTarget(
            threadID: "t1", accountKey: "srv/1", accountID: accountID, emailIDs: [EmailID("e1")])
    }

    /// Answers the session and then whatever the test says to `Email/set`.
    ///
    /// Hand-written rather than through `FakeMailServer`, which has no
    /// `Email/set` at all — and answering `unknownMethod` would make every one
    /// of these tests exercise the refusal path.
    private func makeClient(
        answering: @escaping @Sendable () throws -> Data
    ) -> JMAPClient {
        let transport = MockTransport { request in
            if request.url?.path.hasSuffix("/.well-known/jmap") == true {
                return (Canned.sessionJSON, MockTransport.response(for: request))
            }

            return (try answering(), MockTransport.response(for: request))
        }

        return JMAPClient(
            discoveryURL: URL(string: "https://fake.test/.well-known/jmap")!,
            credential: .appPassword("plmail_" + String(repeating: "a", count: 64)),
            transport: transport
        )
    }

    // MARK: - Queueing

    /// The whole point. The row stays gone, the change is on disk, and the bar
    /// says the server has not been told rather than claiming it has.
    @Test("an archive made with the server unreachable is kept, not rolled back")
    func queuesOnTransportFailure() async throws {
        let store = try await makeStore()
        let queue = makeQueue()
        let actions = MailActions(
            client: makeClient(answering: { throw URLError(.notConnectedToInternet) }),
            store: store,
            queue: queue
        )

        await actions.archive(target)

        #expect(await queue.pending().map(\.kind) == [.archive])
        #expect(actions.queuedCount == 1)
        #expect(actions.pending?.isQueued == true)
        // Not a failure: nothing went wrong that the user has to act on.
        #expect(actions.failure == nil)
        // The row stayed gone, which is what the user watched happen.
        #expect(try await store.feedRows(feedID: FeedID.unified(.inbox).rawValue).isEmpty)
    }

    /// Replaying a refusal is a loop that terminates never, so the row goes
    /// back instead — and the user is told, because the app and the server
    /// otherwise disagree about where their mail is.
    @Test("a server refusal is not queued and the row comes back")
    func doesNotQueueRefusals() async throws {
        let store = try await makeStore()
        let queue = makeQueue()
        let actions = MailActions(
            client: makeClient(answering: { Canned.refused }), store: store, queue: queue)

        await actions.archive(target)

        #expect(await queue.pending().isEmpty)
        #expect(actions.queuedCount == 0)
        #expect(actions.failure != nil)
        #expect(actions.pending == nil)
        #expect(
            try await store.feedRows(feedID: FeedID.unified(.inbox).rawValue)
                .map(\.threadID) == ["t1"])
    }

    /// Taking back a change that never left the device means deleting it from
    /// the queue, not sending its opposite: an inverse the server never saw the
    /// original of would either fail the same way or, worse, arrive first.
    @Test("undoing a queued action removes it from the queue")
    func undoingAQueuedActionEmptiesTheQueue() async throws {
        let store = try await makeStore()
        let queue = makeQueue()
        let actions = MailActions(
            client: makeClient(answering: { throw URLError(.notConnectedToInternet) }),
            store: store,
            queue: queue
        )

        await actions.archive(target)
        await actions.undo()

        #expect(await queue.pending().isEmpty)
        #expect(actions.queuedCount == 0)
        #expect(
            try await store.feedRows(feedID: FeedID.unified(.inbox).rawValue)
                .map(\.threadID) == ["t1"])
    }

    /// Never resurrect a conversation the user archived offline. The server
    /// still says it is in the Inbox, because it has not been told.
    @Test("a queued conversation is named so a sync cannot put it back")
    func pendingTargetsCoverTheThread() async throws {
        let store = try await makeStore()
        let queue = makeQueue()
        let actions = MailActions(
            client: makeClient(answering: { throw URLError(.notConnectedToInternet) }),
            store: store,
            queue: queue
        )

        await actions.archive(target)

        #expect(await queue.pendingTargets() == ["srv/1#t1"])
    }

    // MARK: - Undo

    /// There was no way back from the way back: `undo()` cleared `pending` and
    /// a mis-tap on Undo could only be fixed by redoing the gesture by hand.
    @Test("an undo is itself undoable")
    func undoIsUndoable() async throws {
        let store = try await makeStore()
        let actions = MailActions(
            client: makeClient(answering: { Canned.accepted }), store: store, queue: makeQueue())

        await actions.archive(target)

        #expect(actions.pending?.message == "Archived")

        await actions.undo()

        let second = try #require(actions.pending)

        #expect(second.message == String(localized: "Put back", bundle: .module))

        await actions.undo()

        #expect(actions.pending?.message == "Archived")
    }

    /// The one control in the app with a deadline. A fixed six seconds excludes
    /// exactly the people who need longer, so the shell has to be able to hand
    /// down the system's own recommended timeout.
    @Test("the undo window can be replaced by the shell")
    func undoWindowIsSettable() async throws {
        let store = try await makeStore()
        let actions = MailActions(
            client: makeClient(answering: { Canned.accepted }), store: store, queue: makeQueue())

        actions.undoWindow = .seconds(30)

        #expect(actions.undoWindow == .seconds(30))
    }

    // MARK: - Snooze

    /// A bulk snooze over conversations sleeping until three different days has
    /// three correct answers. Undoing to `nil` wakes the lot and loses times the
    /// user chose and cannot get back from anywhere.
    @Test("an undo of a bulk snooze is grouped by each conversation's own previous time")
    func snoozeUndoGroupsByPreviousTime() {
        let friday = Date(timeIntervalSince1970: 1_700_000_000)
        let monday = Date(timeIntervalSince1970: 1_800_000_000)

        let targets = (1...3).map {
            ActionTarget(
                threadID: "t\($0)", accountKey: "srv/1", accountID: AccountID("1"),
                emailIDs: [EmailID("e\($0)")])
        }

        let groups = MailActions.groupedByPreviousTime(
            targets,
            previousByTarget: [
                "srv/1#t1": friday,
                "srv/1#t2": friday,
                "srv/1#t3": nil,
            ])

        #expect(groups.count == 2)
        #expect(groups.first(where: { $0.0 == friday })?.1.count == 2)
        #expect(groups.first(where: { $0.0 == nil })?.1.map(\.threadID) == ["t3"])
        #expect(groups.contains { $0.0 == monday } == false)
    }
}

/// Canned wire answers, outside the `@MainActor` suite so a `@Sendable`
/// transport closure can read them without hopping actors.
private enum Canned {
    static let sessionJSON = Data(
        """
        {
          "capabilities": {
            "urn:ietf:params:jmap:core": {
              "maxSizeUpload": 50000000, "maxConcurrentUpload": 4,
              "maxSizeRequestObject": 10000000, "maxConcurrentRequests": 4,
              "maxCallsInRequest": 32, "maxObjectsInGet": 500,
              "maxObjectsInSet": 500, "collationAlgorithms": []
            }
          },
          "accounts": {
            "1": {
              "name": "account-1@example.test",
              "isPersonal": true,
              "isReadOnly": false,
              "accountCapabilities": { "urn:ietf:params:jmap:mail": {} }
            }
          },
          "primaryAccounts": { "urn:ietf:params:jmap:mail": "1" },
          "username": "fake@example.test",
          "apiUrl": "https://fake.test/jmap/api",
          "downloadUrl": "https://fake.test/jmap/download/{accountId}/{blobId}/{name}",
          "uploadUrl": "https://fake.test/jmap/upload/{accountId}",
          "eventSourceUrl": "https://fake.test/jmap/eventsource",
          "state": "1"
        }
        """.utf8)

    /// A whole response body rather than a result object, so these can be
    /// `Sendable` and read from the transport's closure without a hop.
    static let accepted = Data(
        """
        {
          "methodResponses": [
            ["Email/set", { "accountId": "1", "newState": "2", "updated": { "e1": null } }, "c0"]
          ],
          "sessionState": "1"
        }
        """.utf8)

    /// A 200 carrying a per-object refusal — the shape a client that reads the
    /// HTTP status as the answer gets wrong.
    static let refused = Data(
        """
        {
          "methodResponses": [
            ["Email/set", {
              "accountId": "1", "newState": "2",
              "notUpdated": { "e1": { "type": "invalidProperties" } }
            }, "c0"]
          ],
          "sessionState": "1"
        }
        """.utf8)
}
