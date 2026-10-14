import Foundation
import JMAPTestSupport
import Testing

@testable import JMAPKit

@Suite("JMAPClient")
struct JMAPClientTests {
    private let discoveryURL = URL(string: "https://nas.local/plmail/.well-known/jmap")!
    private let credential = Credential.appPassword("plmail_" + String(repeating: "a", count: 64))

    // MARK: - Session discovery

    /// Ten callers at launch — the sidebar, the feed, one syncer per account —
    /// must not become ten identical requests to someone's NAS.
    @Test("concurrent callers share one session fetch")
    func sessionIsSingleFlighted() async throws {
        let transport = MockTransport(
            body: try Fixture.data("session"),
            delay: .milliseconds(20)
        )
        let client = JMAPClient(
            discoveryURL: discoveryURL, credential: credential, transport: transport)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask { _ = try? await client.session() }
            }
        }

        #expect(transport.requestCount == 1)
    }

    @Test("a fetched session is reused, and invalidation forces a refetch")
    func sessionIsCached() async throws {
        let transport = MockTransport(body: try Fixture.data("session"))
        let client = JMAPClient(
            discoveryURL: discoveryURL, credential: credential, transport: transport)

        _ = try await client.session()
        _ = try await client.session()
        #expect(transport.requestCount == 1)

        // The URLs in a session belong to the server. Caching them across a
        // reverse-proxy change would mean silently talking to the wrong place.
        await client.invalidateSession()
        _ = try await client.session()
        #expect(transport.requestCount == 2)
    }

    /// A failure must not be cached: the next caller should retry, not inherit
    /// an error from a NAS that was rebooting a second ago.
    @Test("a failed session fetch is not cached")
    func failureIsNotCached() async throws {
        let transport = MockTransport(body: Data("{}".utf8), statusCode: 500)
        let client = JMAPClient(
            discoveryURL: discoveryURL, credential: credential, transport: transport)

        _ = try? await client.session()
        _ = try? await client.session()

        #expect(transport.requestCount == 2)
    }

    @Test("the credential travels as a Bearer token on every request")
    func authorizationHeader() async throws {
        let transport = MockTransport(body: try Fixture.data("session"))
        let client = JMAPClient(
            discoveryURL: discoveryURL, credential: credential, transport: transport)

        _ = try await client.session()

        // The plmail_ prefix routes the token to the app-password
        // authenticator; without it the server tries to read it as a JWT and
        // the failure names the wrong thing.
        #expect(transport.recorded[0].authorization?.hasPrefix("Bearer plmail_") == true)
    }

    @Test("a 401 on discovery becomes a re-auth signal, not a transport error")
    func unauthorizedDiscovery() async throws {
        let transport = MockTransport(
            body: try Fixture.data("problem-401"),
            statusCode: 401
        )
        let client = JMAPClient(
            discoveryURL: discoveryURL, credential: credential, transport: transport)

        await #expect(
            throws: JMAPError.notAuthenticated(detail: "Invalid or revoked app password.")
        ) {
            try await client.session()
        }
    }

    // MARK: - Requests

    @Test("a batch posts to the session's apiUrl, never to a constructed path")
    func requestsUseDiscoveredURL() async throws {
        let transport = ScriptedTransport(
            session: try Fixture.data("session"),
            api: try Fixture.data("batch-with-inline-error")
        )
        let client = JMAPClient(
            discoveryURL: discoveryURL, credential: credential, transport: transport.transport)

        var builder = RequestBuilder()
        builder.add(MailboxGet(accountID: AccountID("7")))
        _ = try await client.send(builder)

        let posted = try #require(transport.transport.recorded.last)

        #expect(posted.method == "POST")
        #expect(posted.url.absoluteString == "https://nas.local/plmail/jmap/api")
    }

    @Test("an empty batch is refused before it reaches the network")
    func emptyBatchIsRefused() async throws {
        let transport = MockTransport(body: try Fixture.data("session"))
        let client = JMAPClient(
            discoveryURL: discoveryURL, credential: credential, transport: transport)

        await #expect(throws: JMAPError.self) {
            try await client.send(RequestBuilder())
        }
        #expect(transport.requestCount == 0)
    }

    // MARK: - Concurrency

    /// The session advertises `maxConcurrentRequests: 4`, and on plMail that
    /// is a real capacity limit rather than a courtesy: exceeding it occupies
    /// every PHP worker and the server stops answering anyone, including the
    /// web UI.
    @Test("in-flight requests never exceed the server's advertised limit")
    func gateHoldsConcurrencyDown() async throws {
        let transport = ScriptedTransport(
            session: try Fixture.data("session"),
            api: try Fixture.data("batch-with-inline-error"),
            apiDelay: .milliseconds(20)
        )
        let client = JMAPClient(
            discoveryURL: discoveryURL, credential: credential, transport: transport.transport)

        _ = try await client.session()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    var builder = RequestBuilder()
                    builder.add(MailboxGet(accountID: AccountID("7")))
                    _ = try? await client.send(builder)
                }
            }
        }

        #expect(transport.transport.peakConcurrency <= 4)
        #expect(transport.transport.requestCount == 13)
    }

    @Test("reserving a permit for a long-lived connection narrows the gate")
    func reservationNarrowsTheGate() async throws {
        let gate = RequestGate(capacity: 4)
        let reservation = await gate.reserve()

        let observed = await peakConcurrency(of: gate, tasks: 8)
        #expect(observed <= 3)

        await reservation.end()

        let afterRelease = await peakConcurrency(of: gate, tasks: 8)
        #expect(afterRelease <= 4)
    }

    /// Reserving must never take the last permit: a client that then needed to
    /// make a request would wait forever on itself.
    @Test("a reservation cannot starve the gate")
    func reservationLeavesRoom() async throws {
        let gate = RequestGate(capacity: 1)
        let reservation = await gate.reserve()

        // Would hang rather than fail if the reservation had taken the permit.
        await gate.withPermit {}
        await reservation.end()
    }

    private func peakConcurrency(of gate: RequestGate, tasks: Int) async -> Int {
        let counter = Counter()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<tasks {
                group.addTask {
                    await gate.withPermit {
                        await counter.enter()
                        try? await Task.sleep(for: .milliseconds(10))
                        await counter.leave()
                    }
                }
            }
        }

        return await counter.peak
    }
}

private actor Counter {
    private(set) var peak = 0
    private var current = 0

    func enter() {
        current += 1
        peak = max(peak, current)
    }

    func leave() {
        current -= 1
    }
}

/// Answers session discovery and API calls with different bodies, which is
/// what any test past the first round trip needs.
private struct ScriptedTransport {
    let transport: MockTransport

    init(session: Data, api: Data, apiDelay: Duration = .zero) {
        transport = MockTransport { request in
            let isDiscovery = request.url?.path.hasSuffix("/.well-known/jmap") == true

            if isDiscovery == false, apiDelay > .zero {
                try await Task.sleep(for: apiDelay)
            }

            return (
                isDiscovery ? session : api,
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }
    }
}
