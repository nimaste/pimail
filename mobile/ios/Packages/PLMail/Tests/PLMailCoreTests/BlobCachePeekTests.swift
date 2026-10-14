import Foundation
import JMAPKit
import Testing

@testable import PLMailCore

/// ``BlobCache/cachedFile(blobID:accountID:name:type:)`` is the single call the
/// attachment grid makes while drawing, so the whole "appearing on screen
/// costs nothing" promise is only as good as this suite.
///
/// The guarantee under test is negative and therefore easy to lose to a
/// well-meant edit: peeking must not download, must not create anything on
/// disk, and must answer nil rather than blocking on a request. A version that
/// quietly fell back to ``BlobCache/file(blobID:accountID:name:type:downloadURL:credential:)``
/// would look identical in the reader and turn a scroll into a download storm.
/// Serialized because the request counter below is process-wide: `URLProtocol`
/// registration is, and two of these running at once would each see the
/// other's requests and every count would be wrong in a way that looks like
/// flakiness rather than like a shared static.
@Suite("Blob cache peeking", .serialized)
struct BlobCachePeekTests {
    /// A `URLSession` that counts what it is asked for and serves one canned
    /// body, so "no request was made" is an assertion rather than a hope.
    private final class CountingProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var requestCount = 0
        nonisolated(unsafe) static var body = Data("bytes".utf8)

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.requestCount += 1

            guard
                let url = request.url,
                let response = HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
            else { return }

            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func makeCache() -> BlobCache {
        CountingProtocol.requestCount = 0

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CountingProtocol.self]

        // A fresh server id per test, so one test's leftovers cannot make
        // another's peek succeed for the wrong reason.
        return BlobCache(
            serverID: "thumbnail-tests-\(UUID().uuidString)",
            session: URLSession(configuration: configuration))
    }

    private let downloadURL = URLTemplate(
        "https://nas.local/jmap/download/{accountId}/{blobId}/{name}?accept={type}")

    @Test("Peeking at a blob that was never fetched answers nil and makes no request")
    func peekDoesNotFetch() async {
        let cache = makeCache()

        let url = await cache.cachedFile(
            blobID: BlobID("b1"), accountID: AccountID("1"), name: "photo.jpg", type: "image/jpeg")

        #expect(url == nil)
        #expect(CountingProtocol.requestCount == 0)

        await cache.removeAll()
    }

    @Test("Peeking forty times, as a scroll would, still makes no request")
    func repeatedPeeksDoNotFetch() async {
        let cache = makeCache()

        for index in 0..<40 {
            _ = await cache.cachedFile(
                blobID: BlobID("b\(index)"),
                accountID: AccountID("1"),
                name: "photo.jpg",
                type: "image/jpeg")
        }

        #expect(CountingProtocol.requestCount == 0)

        await cache.removeAll()
    }

    @Test("A blob the user already opened is found by a peek, with no second request")
    func peekFindsADownloadedBlob() async throws {
        let cache = makeCache()

        let downloaded = try await cache.file(
            blobID: BlobID("b1"),
            accountID: AccountID("1"),
            name: "photo.jpg",
            type: "image/jpeg",
            downloadURL: downloadURL,
            credential: .appPassword("plmail_secret"))

        #expect(CountingProtocol.requestCount == 1)

        let peeked = try #require(
            await cache.cachedFile(
                blobID: BlobID("b1"),
                accountID: AccountID("1"),
                name: "photo.jpg",
                type: "image/jpeg"))

        #expect(peeked == downloaded)
        #expect(CountingProtocol.requestCount == 1)

        await cache.removeAll()
    }

    @Test("A peek for a different account does not find another account's blob")
    func peekIsScopedToTheAccount() async throws {
        let cache = makeCache()

        _ = try await cache.file(
            blobID: BlobID("b1"),
            accountID: AccountID("1"),
            name: "photo.jpg",
            type: "image/jpeg",
            downloadURL: downloadURL,
            credential: .appPassword("plmail_secret"))

        let other = await cache.cachedFile(
            blobID: BlobID("b1"), accountID: AccountID("2"), name: "photo.jpg", type: "image/jpeg")

        #expect(other == nil)
        #expect(CountingProtocol.requestCount == 1)

        await cache.removeAll()
    }

    @Test("Everything a peek can find survives the network going away")
    func peekWorksOffline() async throws {
        let cache = makeCache()

        _ = try await cache.file(
            blobID: BlobID("b1"),
            accountID: AccountID("1"),
            name: "photo.jpg",
            type: "image/jpeg",
            downloadURL: downloadURL,
            credential: .appPassword("plmail_secret"))

        // Nothing in the peek path consults the session, so there is no
        // network to take away — which is the point. The assertion is that a
        // second peek needs no request at all.
        let peeked = await cache.cachedFile(
            blobID: BlobID("b1"), accountID: AccountID("1"), name: "photo.jpg", type: "image/jpeg")

        #expect(peeked != nil)
        #expect(CountingProtocol.requestCount == 1)

        await cache.removeAll()
    }
}
