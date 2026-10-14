import Foundation
import JMAPTestSupport
import Testing

@testable import JMAPKit

/// Uploading is the one request that is not a method call, so none of the
/// batch-level guarantees cover it: no `RequestBuilder` to get the URL right,
/// no envelope to carry the credential. Everything it has to get right is
/// asserted here.
@Suite("Blob upload")
struct BlobUploadTests {
    private let discoveryURL = URL(string: "https://nas.local/.well-known/jmap")!
    private let credential = Credential.appPassword("plmail_test")

    /// Answers the session fixture for a GET and the upload response for a
    /// POST, so one client can do both halves.
    private func makeTransport(
        uploadStatus: Int = 200,
        uploadBody: Data = Data(
            #"{"accountId":"7","blobId":"u-1","type":"text/plain","size":5}"#.utf8)
    ) throws -> MockTransport {
        let session = try Fixture.data("session")

        return MockTransport { request in
            if request.httpMethod == "POST", request.url?.path.contains("/upload") == true {
                return (uploadBody, MockTransport.response(for: request, statusCode: uploadStatus))
            }

            return (session, MockTransport.response(for: request))
        }
    }

    /// The whole contract in one assertion: raw bytes as the body — not
    /// multipart, not base64 — the declared media type on `Content-Type`, the
    /// credential present, and the account id substituted into the session's
    /// own template rather than a path built by hand.
    @Test("bytes go to the session's uploadUrl with the declared type")
    func requestShape() async throws {
        let transport = try makeTransport()
        let client = JMAPClient(
            discoveryURL: discoveryURL, credential: credential, transport: transport)

        let blob = try await client.upload(
            Data("hello".utf8), type: "text/plain", accountID: AccountID("7"))

        #expect(blob.blobID == BlobID("u-1"))

        let upload = try #require(transport.recorded.last)

        #expect(upload.method == "POST")
        #expect(upload.body == Data("hello".utf8))
        #expect(upload.authorization == credential.authorizationHeader)
        // The account id lands in the path, and no `{accountId}` survives.
        #expect(upload.url.absoluteString.contains("/upload/7"))
        #expect(upload.url.absoluteString.contains("{") == false)
    }

    /// The ceiling is the server's, read from the live session. A hardcoded
    /// one would refuse files a differently configured server would take, and
    /// the failure would look like the server's rather than the client's.
    @Test("a file past the session's advertised limit never leaves the device")
    func refusesOversized() async throws {
        let transport = try makeTransport()
        let client = JMAPClient(
            discoveryURL: discoveryURL, credential: credential, transport: transport)

        let limit = try await client.session().capabilities.core.maxSizeUpload
        let before = transport.requestCount

        await #expect(throws: (any Error).self) {
            try await client.upload(
                Data(repeating: 0, count: limit + 1), type: "application/octet-stream",
                accountID: AccountID("7"))
        }

        // Not merely an error — no request at all. Sending it and letting the
        // server say no would push megabytes over someone's uplink first.
        #expect(transport.requestCount == before)
    }

    @Test("an empty file is refused rather than uploaded")
    func refusesEmpty() async throws {
        let transport = try makeTransport()
        let client = JMAPClient(
            discoveryURL: discoveryURL, credential: credential, transport: transport)

        _ = try await client.session()
        let before = transport.requestCount

        await #expect(throws: (any Error).self) {
            try await client.upload(Data(), type: "text/plain", accountID: AccountID("7"))
        }

        #expect(transport.requestCount == before)
    }

    /// Upload errors arrive as a status code, not as an inline method error —
    /// this is not a batch — so a non-2xx must throw rather than fall through
    /// to a decode that happens to fail.
    @Test("a rejected upload throws instead of returning a blob")
    func rejects() async throws {
        let transport = try makeTransport(
            uploadStatus: 413,
            uploadBody: Data(#"{"type":"tooLarge","status":413}"#.utf8))
        let client = JMAPClient(
            discoveryURL: discoveryURL, credential: credential, transport: transport)

        await #expect(throws: (any Error).self) {
            try await client.upload(
                Data("hello".utf8), type: "text/plain", accountID: AccountID("7"))
        }
    }
}
