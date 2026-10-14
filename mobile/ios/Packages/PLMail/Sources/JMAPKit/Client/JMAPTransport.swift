import Foundation

/// Where bytes actually go.
///
/// A protocol so the whole client above it can be tested without a network,
/// a server or a simulator — which is the difference between a sync-engine
/// test suite that runs and one that doesn't.
public protocol JMAPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}
