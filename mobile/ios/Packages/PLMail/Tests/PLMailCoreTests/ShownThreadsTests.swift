import Foundation
import JMAPKit
import JMAPTestSupport
import Synchronization
import Testing

@testable import PLMailCore

/// Reporting displays is the half of the New marker that keeps every *other*
/// client honest: only a client that draws a row can retire that row's marker,
/// so an app that badges without reporting leaves the web UI and Android
/// badging mail the user has already read.
///
/// These are the three guarantees that make it safe to call on every row of
/// every draw — reported once, batched, and never losing the marker when the
/// server cannot be reached.
@Suite("Reporting displayed conversations")
struct ShownThreadsTests {
    private static let accountID = AccountID("1")

    private func makeStore() -> SyncStore {
        SyncStore(modelContainer: MailStack.makeContainer(inMemory: true))
    }

    /// Seeds two conversations, both carrying the marker.
    private func seed(_ store: SyncStore) async throws {
        var first = Email(id: EmailID("e1"))
        first.threadID = ThreadID("t1")
        first.receivedAt = UTCDate(Date(timeIntervalSince1970: 1_700_000_000))

        var second = Email(id: EmailID("e2"))
        second.threadID = ThreadID("t2")
        second.receivedAt = UTCDate(Date(timeIntervalSince1970: 1_700_000_100))

        try await store.upsert(
            emails: [first, second],
            threads: [
                MailThread(id: ThreadID("t1"), emailIDs: [EmailID("e1")], isNew: true),
                MailThread(id: ThreadID("t2"), emailIDs: [EmailID("e2")], isNew: true),
            ],
            accountKey: "srv/1",
            emailState: nil)
    }

    /// Answers the session, then hands every API call to `answering`.
    ///
    /// The transport comes back alongside the client because the batching
    /// guarantee is a claim about **how many requests went out**, which is
    /// invisible from a decoded result — `MockTransport.recorded` is the only
    /// place it can be read.
    private func makeClient(
        answering: @escaping @Sendable () throws -> Data
    ) -> (client: JMAPClient, transport: MockTransport) {
        let transport = MockTransport { request in
            if request.url?.path.hasSuffix("/.well-known/jmap") == true {
                return (Canned.session, MockTransport.response(for: request))
            }

            return (try answering(), MockTransport.response(for: request))
        }

        let client = JMAPClient(
            discoveryURL: URL(string: "https://fake.test/.well-known/jmap")!,
            credential: .appPassword("plmail_" + String(repeating: "a", count: 64)),
            transport: transport
        )

        return (client, transport)
    }

    /// The API request bodies, with the session fetch filtered out — it is
    /// single-flighted and would otherwise be counted as a round trip the
    /// reporter made.
    private func posts(_ transport: MockTransport) -> [String] {
        transport.recorded
            .filter { $0.url.path.hasSuffix("/.well-known/jmap") == false }
            .compactMap { $0.body.flatMap { String(data: $0, encoding: .utf8) } }
    }

    // MARK: - Reported once

    /// A list row appears every time it is scrolled back onto screen. The
    /// server's own idempotence does not make those free — they are still
    /// requests against what is frequently a Raspberry Pi.
    @Test("a row drawn many times is reported once")
    func reportsOnce() async throws {
        let store = makeStore()
        try await seed(store)

        let (client, transport) = makeClient(answering: { Canned.accepted })
        let shown = ShownThreads(client: client, store: store)

        for _ in 0..<20 {
            await shown.report(threadID: "t1", accountKey: "srv/1", accountID: Self.accountID)
        }

        await shown.flushNow()

        let sent = posts(transport)

        #expect(sent.count == 1)
        // One id in the patch, not twenty.
        #expect(sent[0].components(separatedBy: "\"t1\"").count - 1 == 1)
    }

    // MARK: - Batched

    /// The guarantee that keeps a scroll from becoming a request per row.
    @Test("a page of rows becomes one request, not one per row")
    func batches() async throws {
        let store = makeStore()
        try await seed(store)

        let (client, transport) = makeClient(answering: { Canned.accepted })
        let shown = ShownThreads(client: client, store: store)

        await shown.report(threadID: "t1", accountKey: "srv/1", accountID: Self.accountID)
        await shown.report(threadID: "t2", accountKey: "srv/1", accountID: Self.accountID)

        // Both are still waiting: nothing goes out on the reporting call
        // itself, which is what stops a scroll blocking on a home server.
        #expect(await shown.pendingCount == 2)

        await shown.flushNow()

        let sent = posts(transport)

        #expect(sent.count == 1)

        let body = sent[0]

        #expect(body.contains("Thread/set"))
        #expect(body.contains("\"t1\""))
        #expect(body.contains("\"t2\""))
        // `false` and only `false`. The server refuses `true` with
        // `invalidProperties`, and a patch that could set it would let a client
        // keep its own badges alive forever.
        #expect(body.contains("\"isNew\":false"))
    }

    /// **The one that would silently wake every snoozed conversation on
    /// screen.** A retirement patch and a snooze patch share a type, and if
    /// "not mentioned" and "explicitly null" were the same value, reporting a
    /// row would carry `snoozedUntil: null` and pull the conversation back into
    /// the Inbox.
    @Test("a display report says nothing about the snooze")
    func doesNotTouchSnooze() async throws {
        let store = makeStore()
        try await seed(store)

        let (client, transport) = makeClient(answering: { Canned.accepted })
        let shown = ShownThreads(client: client, store: store)

        await shown.report(threadID: "t1", accountKey: "srv/1", accountID: Self.accountID)
        await shown.flushNow()

        #expect(try #require(posts(transport).first).contains("snoozedUntil") == false)
    }

    // MARK: - Failure

    /// Losing the marker locally while the server still holds it is the worse
    /// of the two failures: the badge would be gone here and still up in the
    /// browser, with nothing left on screen to retire it.
    @Test("a report the server never received leaves the marker alone")
    func keepsMarkerOnFailure() async throws {
        let store = makeStore()
        try await seed(store)

        let shown = ShownThreads(
            client: makeClient(answering: { throw URLError(.timedOut) }).client, store: store)

        await shown.report(threadID: "t1", accountKey: "srv/1", accountID: Self.accountID)
        await shown.flushNow()

        #expect(try await store.newMarkers(threadIDs: ["t1"], accountKey: "srv/1") == ["t1"])
    }

    /// Failure is cheap because the row will be drawn again — but only if the
    /// de-duplication guard lets it through a second time.
    @Test("a failed report is retried the next time the row is drawn")
    func retriesAfterFailure() async throws {
        let store = makeStore()
        try await seed(store)

        let shouldFail = Mutex(true)
        let (client, transport) = makeClient(answering: {
            if shouldFail.withLock({ $0 }) { throw URLError(.timedOut) }

            return Canned.accepted
        })
        let shown = ShownThreads(client: client, store: store)

        await shown.report(threadID: "t1", accountKey: "srv/1", accountID: Self.accountID)
        await shown.flushNow()

        shouldFail.withLock { $0 = false }

        await shown.report(threadID: "t1", accountKey: "srv/1", accountID: Self.accountID)
        await shown.flushNow()

        #expect(posts(transport).count == 2)
        #expect(try await store.newMarkers(threadIDs: ["t1"], accountKey: "srv/1").isEmpty)
    }

    /// The accepted case, spelled out: the column is cleared only once the
    /// server has actually taken the write.
    @Test("an accepted report clears the marker on this device too")
    func clearsMarkerOnSuccess() async throws {
        let store = makeStore()
        try await seed(store)

        let shown = ShownThreads(
            client: makeClient(answering: { Canned.accepted }).client, store: store)

        await shown.report(threadID: "t1", accountKey: "srv/1", accountID: Self.accountID)
        await shown.report(threadID: "t2", accountKey: "srv/1", accountID: Self.accountID)
        await shown.flushNow()

        #expect(try await store.newMarkers(threadIDs: ["t1", "t2"], accountKey: "srv/1").isEmpty)
    }

    // MARK: - The wire type

    /// A patch that mentions the snooze must still encode an explicit null,
    /// because that is how the API spells "clear it" — the opposite of the
    /// omission the display report needs.
    @Test("a snooze patch still clears with an explicit null")
    func snoozePatchStillEncodesNull() throws {
        let request = ThreadSet.snooze(ThreadID("t1"), until: nil, accountID: Self.accountID)
        let encoded = try JSONEncoder().encode(request.arguments)
        let body = try #require(String(data: encoded, encoding: .utf8))

        #expect(body.contains("\"snoozedUntil\":null"))
        #expect(body.contains("isNew") == false)
    }
}

private enum Canned {
    static let session = Data(
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

    static let accepted = Data(
        """
        {
          "methodResponses": [
            ["Thread/set", {
              "accountId": "1", "oldState": "1", "newState": "2",
              "updated": { "t1": null, "t2": null }, "notUpdated": {}
            }, "c0"]
          ],
          "sessionState": "1"
        }
        """.utf8)
}
