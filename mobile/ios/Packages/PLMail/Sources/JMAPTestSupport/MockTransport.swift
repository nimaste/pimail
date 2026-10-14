public import Foundation
public import JMAPKit
import Synchronization

/// A transport that answers from a closure instead of a network.
///
/// Records every request, so tests can assert on what was actually sent — the
/// authorization header, the concurrency, the number of round trips — none of
/// which is visible from a decoded result.
public final class MockTransport: JMAPTransport {
    public struct Recorded: Sendable {
        public var url: URL
        public var method: String
        public var authorization: String?
        public var body: Data?
    }

    private struct State {
        var recorded: [Recorded] = []
        var inFlight = 0
        var peakInFlight = 0
    }

    private let state = Mutex(State())
    private let handler: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    public init(handler: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)) {
        self.handler = handler
    }

    /// Always answers with the same body and status.
    public convenience init(body: Data, statusCode: Int = 200, delay: Duration = .zero) {
        self.init { request in
            if delay > .zero { try await Task.sleep(for: delay) }

            return (body, Self.response(for: request, statusCode: statusCode))
        }
    }

    public var recorded: [Recorded] { state.withLock(\.recorded) }
    public var requestCount: Int { state.withLock(\.recorded.count) }

    /// The most requests ever in flight at once — how the concurrency gate is
    /// tested without depending on timing.
    public var peakConcurrency: Int { state.withLock(\.peakInFlight) }

    public static func response(for request: URLRequest, statusCode: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url ?? URL(string: "https://invalid.test")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        state.withLock {
            $0.recorded.append(
                Recorded(
                    url: request.url ?? URL(string: "https://invalid.test")!,
                    method: request.httpMethod ?? "GET",
                    authorization: request.value(forHTTPHeaderField: "Authorization"),
                    body: request.httpBody
                )
            )
            $0.inFlight += 1
            $0.peakInFlight = max($0.peakInFlight, $0.inFlight)
        }

        defer { state.withLock { $0.inFlight -= 1 } }

        return try await handler(request)
    }
}
