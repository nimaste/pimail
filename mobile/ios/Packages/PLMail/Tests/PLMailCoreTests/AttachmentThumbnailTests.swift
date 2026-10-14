import Foundation
import JMAPKit
import Testing

@testable import PLMailCore

/// The thumbnail grid is the feature most likely to quietly undo this app's
/// one architectural promise — that it does not download eagerly, because the
/// server is somebody's NAS with a single PHP worker pool.
///
/// So these tests are about the brakes, not about pictures. Every one of them
/// asserts that something did **not** happen: that drawing does not fetch,
/// that a ceiling holds, that a failure is not retried, that offline spends
/// nothing. A suite that only proved a JPEG becomes an image would pass
/// happily on a build that fetched every attachment in every thread.
@Suite("Attachment thumbnails")
struct AttachmentThumbnailTests {
    private func attachment(
        blobID: String = "b1",
        name: String? = "photo.jpg",
        type: String = "image/jpeg",
        size: Int = 200_000
    ) -> AttachmentSnapshot {
        AttachmentSnapshot(
            partID: "p-\(blobID)",
            blobID: blobID,
            name: name,
            type: type,
            size: size,
            cid: nil,
            isInline: false)
    }

    // MARK: - Nothing is fetched by drawing

    @Test("Drawing a tile fetches nothing, however previewable the attachment is")
    func drawingDoesNotFetch() {
        let policy = AttachmentThumbnailPolicy()

        #expect(
            policy.decision(for: attachment(), in: .init(isUserInitiated: false))
                == .placeholder(.notRequested))
    }

    @Test("Scrolling a thread of previewable attachments still fetches nothing")
    func scrollingDoesNotFetch() {
        let policy = AttachmentThumbnailPolicy()
        let thread = (0..<40).map { attachment(blobID: "b\($0)") }

        // What a scroll does: ask about every tile it draws, repeatedly.
        let decisions = thread.map { policy.decision(for: $0, in: .init()) }

        #expect(decisions.allSatisfy { $0 == .placeholder(.notRequested) })
        #expect(policy.hasAnythingWorthFetching(thread, in: .init()) == false)
    }

    @Test("A tap is the only thing that turns a previewable attachment into a download")
    func tapFetches() {
        let policy = AttachmentThumbnailPolicy()

        #expect(policy.decision(for: attachment(), in: .init(isUserInitiated: true)) == .download)
    }

    // MARK: - Bytes already here are free

    @Test("Bytes already in the cache render without a tap and without a network")
    func cachedBytesRenderOffline() {
        let policy = AttachmentThumbnailPolicy()
        let context = AttachmentThumbnailPolicy.Context(
            isOnDisk: true, isUserInitiated: false, isDeviceOffline: true)

        #expect(policy.decision(for: attachment(), in: context) == .render)
    }

    @Test("A cached file too large to be worth rendering is still refused")
    func cachedButTooLarge() {
        let policy = AttachmentThumbnailPolicy()
        let huge = attachment(name: "scan.tiff", type: "image/tiff", size: 40 * 1024 * 1024)

        #expect(
            policy.decision(for: huge, in: .init(isOnDisk: true))
                == .placeholder(
                    .tooLarge(ceiling: AttachmentThumbnailPolicy.Limits.renderableByteCeiling)))
        #expect(policy.isWorthRendering(huge) == false)
    }

    // MARK: - The ceiling

    @Test("A forty-megabyte TIFF is never fetched for a sixty-point square")
    func sizeCeilingHolds() {
        let policy = AttachmentThumbnailPolicy()
        let huge = attachment(name: "scan.tiff", type: "image/tiff", size: 40 * 1024 * 1024)

        #expect(
            policy.decision(for: huge, in: .init(isUserInitiated: true))
                == .placeholder(
                    .tooLarge(ceiling: AttachmentThumbnailPolicy.Limits.renderableByteCeiling)))
    }

    @Test("A server that publishes a smaller ceiling lowers this client's")
    func serverCeilingLowers() throws {
        let limits = AttachmentThumbnailPolicy.Limits.reading(
            try session(maxSizeAttachmentsPerEmail: 100_000), accountID: AccountID("1"))

        #expect(limits.byteCeiling == 100_000)

        let policy = AttachmentThumbnailPolicy(limits: limits)
        let ordinary = attachment(size: 200_000)

        #expect(
            policy.decision(for: ordinary, in: .init(isUserInitiated: true))
                == .placeholder(.tooLarge(ceiling: 100_000)))
    }

    @Test("A server that publishes fifty megabytes does not raise this client's ceiling")
    func serverCeilingDoesNotRaise() throws {
        let limits = AttachmentThumbnailPolicy.Limits.reading(
            try session(maxSizeAttachmentsPerEmail: 50_000_000), accountID: AccountID("1"))

        #expect(limits.byteCeiling == AttachmentThumbnailPolicy.Limits.renderableByteCeiling)
    }

    @Test("An account that published no ceiling falls back to the local one, not to no limit")
    func unpublishedCeiling() throws {
        let limits = AttachmentThumbnailPolicy.Limits.reading(
            try session(maxSizeAttachmentsPerEmail: nil), accountID: AccountID("1"))

        #expect(limits.byteCeiling == AttachmentThumbnailPolicy.Limits.renderableByteCeiling)
    }

    @Test("Another account's ceiling is never applied to this one")
    func unknownAccountCeiling() throws {
        let limits = AttachmentThumbnailPolicy.Limits.reading(
            try session(maxSizeAttachmentsPerEmail: 100_000), accountID: AccountID("nope"))

        #expect(limits.byteCeiling == AttachmentThumbnailPolicy.Limits.renderableByteCeiling)
    }

    // MARK: - Types not worth the bytes

    @Test(
        "Types whose preview costs far more than it says are never fetched",
        arguments: [
            ("video/mp4", "clip.mp4"),
            ("audio/mpeg", "voice.mp3"),
            ("application/zip", "bundle.zip"),
            ("application/vnd.openxmlformats-officedocument.wordprocessingml.document", "cv.docx"),
            ("text/calendar", "invite.ics"),
            ("application/octet-stream", "unknown"),
            ("image/gif", "spinner.gif"),
        ])
    func notRenderableTypes(type: String, name: String) {
        let policy = AttachmentThumbnailPolicy()
        let part = attachment(name: name, type: type)

        #expect(
            policy.decision(for: part, in: .init(isUserInitiated: true))
                == .placeholder(.notRenderable))
    }

    @Test(
        "Still images and PDFs are the two things worth the bytes",
        arguments: [
            ("image/jpeg", "photo.jpg"),
            ("image/png", "diagram.png"),
            ("image/heic", "photo.heic"),
            ("application/pdf", "invoice.pdf"),
        ])
    func renderableTypes(type: String, name: String) {
        let policy = AttachmentThumbnailPolicy()

        #expect(
            policy.decision(
                for: attachment(name: name, type: type), in: .init(isUserInitiated: true))
                == .download)
    }

    @Test("A scanner that declared octet-stream but named the file .jpg is still a photo")
    func extensionFallback() {
        #expect(
            AttachmentThumbnailPolicy.isRenderable(
                type: "application/octet-stream", name: "IMG_0021.JPG"))
        #expect(
            AttachmentThumbnailPolicy.isRenderable(
                type: "application/octet-stream", name: "archive.zip") == false)
    }

    // MARK: - Failure is not retried

    @Test("A blob that failed once is never asked for again, however many taps arrive")
    func failureIsNotRetried() {
        let policy = AttachmentThumbnailPolicy()
        let context = AttachmentThumbnailPolicy.Context(isUserInitiated: true, hasFailed: true)

        for _ in 0..<20 {
            #expect(policy.decision(for: attachment(), in: context) == .placeholder(.failed))
        }
    }

    @Test("A failed blob whose bytes are on disk is still rendered, because that costs nothing")
    func failedButCached() {
        let policy = AttachmentThumbnailPolicy()

        #expect(
            policy.decision(for: attachment(), in: .init(isOnDisk: true, hasFailed: true))
                == .render)
    }

    // MARK: - Offline

    @Test("Nothing is fetched with no network, even on an explicit tap")
    func offlineFetchesNothing() {
        let policy = AttachmentThumbnailPolicy()
        let context = AttachmentThumbnailPolicy.Context(
            isUserInitiated: true, isDeviceOffline: true)

        #expect(policy.decision(for: attachment(), in: context) == .placeholder(.offline))
        #expect(
            policy.hasAnythingWorthFetching([attachment(), attachment(blobID: "b2")], in: context)
                == false)
    }

    // MARK: - The per-message budget

    @Test("One tap on a message of forty photographs spends a bounded number of requests")
    func perMessageBudget() {
        let policy = AttachmentThumbnailPolicy()
        let budget = AttachmentThumbnailPolicy.Limits.local.perMessage
        var spent = 0

        for index in 0..<40 {
            let decision = policy.decision(
                for: attachment(blobID: "b\(index)"),
                in: .init(isUserInitiated: true, spentInMessage: spent))

            if decision == .download { spent += 1 }
        }

        #expect(spent == budget)
        #expect(
            policy.decision(
                for: attachment(), in: .init(isUserInitiated: true, spentInMessage: budget))
                == .placeholder(.budgetSpent))
    }

    // MARK: - The placeholder is informative on its own

    @Test("An unfetched attachment still says what kind of thing it is")
    func typedPlaceholder() {
        let placeholder = AttachmentThumbnailPolicy.placeholder(
            for: attachment(name: "invoice.pdf", type: "application/pdf"))

        #expect(placeholder.symbolName == "doc.richtext")
        #expect(placeholder.typeDescription?.isEmpty == false)
    }

    @Test("A type nobody recognises describes nothing rather than reciting its MIME string")
    func unknownTypePlaceholder() {
        let placeholder = AttachmentThumbnailPolicy.placeholder(
            for: attachment(name: "thing", type: "application/x-nonsense-not-a-real-type"))

        #expect(placeholder.typeDescription == nil)
        #expect(placeholder.symbolName == "doc")
    }

    // MARK: - Helpers

    /// A Session carrying one account's published attachment ceiling.
    ///
    /// Decoded from JSON rather than constructed, because `Session` has no
    /// public memberwise initialiser and because decoding is what the app
    /// actually does — a test that built the value by hand would not notice a
    /// coding key that stopped matching the server.
    private func session(maxSizeAttachmentsPerEmail: Int?) throws -> Session {
        let published =
            maxSizeAttachmentsPerEmail.map { "\($0)" } ?? "null"

        let json = """
            {
              "capabilities": {
                "urn:ietf:params:jmap:core": {
                  "maxSizeUpload": 50000000,
                  "maxConcurrentUpload": 4,
                  "maxSizeRequestObject": 10000000,
                  "maxConcurrentRequests": 4,
                  "maxCallsInRequest": 32,
                  "maxObjectsInGet": 500,
                  "maxObjectsInSet": 500,
                  "collationAlgorithms": ["i;ascii-numeric"]
                }
              },
              "accounts": {
                "1": {
                  "name": "someone@example.com",
                  "isPersonal": true,
                  "isReadOnly": false,
                  "accountCapabilities": {
                    "urn:ietf:params:jmap:mail": {
                      "maxSizeAttachmentsPerEmail": \(published)
                    }
                  }
                }
              },
              "primaryAccounts": {},
              "username": "someone@example.com",
              "apiUrl": "https://nas.local/jmap/api",
              "downloadUrl": "https://nas.local/jmap/download/{accountId}/{blobId}/{name}?accept={type}",
              "uploadUrl": "https://nas.local/jmap/upload/{accountId}",
              "eventSourceUrl": "https://nas.local/jmap/eventsource",
              "state": "s1"
            }
            """

        return try JSONDecoder().decode(Session.self, from: Data(json.utf8))
    }
}
