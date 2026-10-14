import Foundation
import JMAPKit
import Testing

@testable import PLMailCore

/// The attachment contract, which is the one place in this domain where
/// getting it wrong deletes somebody's files rather than merely annoying them.
@Suite("Draft writing")
struct DraftWritingTests {
    private func encode(_ content: DraftContent) throws -> [String: Any] {
        let method = DraftUpdate(
            accountID: AccountID("1"), emailID: EmailID("42"), content: content)
        let data = try JSONEncoder().encode(method.arguments)
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])

        return json
    }

    private func patch(_ content: DraftContent) throws -> [String: Any] {
        let json = try encode(content)
        let update = try #require(json["update"] as? [String: Any])

        return try #require(update["42"] as? [String: Any])
    }

    /// An unchanged attachment set must not be restated. Every restatement is
    /// another chance for one unresolvable blob id to fail the whole patch —
    /// subject included — and a dozen ids per keystroke over a home uplink.
    @Test("An unchanged attachment set is not sent at all")
    func unchangedAttachmentsAreOmitted() throws {
        let patch = try patch(DraftContent(subject: "Hi", attachments: .unchanged))

        #expect(patch["attachments"] == nil)
        #expect(patch["subject"] as? String == "Hi")
    }

    @Test("A changed attachment set is sent as a whole value")
    func changedAttachmentsAreWhole() throws {
        let patch = try patch(
            DraftContent(
                attachments: .whole([
                    DraftAttachment(blobID: BlobID("p-7"), type: "application/pdf", name: "a.pdf")
                ])))

        let files = try #require(patch["attachments"] as? [[String: Any]])

        #expect(files.count == 1)
        #expect(files[0]["blobId"] as? String == "p-7")
        #expect(files[0]["name"] as? String == "a.pdf")
    }

    /// An emptied set is a distinct, destructive statement and has to be
    /// expressible — omitting the key would silently keep files the user
    /// removed.
    @Test("Removing the last file sends an empty array, not nothing")
    func emptiedAttachments() throws {
        let patch = try patch(DraftContent(attachments: .whole([])))

        #expect(patch["attachments"] as? [Any] != nil)
        #expect((patch["attachments"] as? [Any])?.isEmpty == true)
    }

    /// `from` is not in the server's draft-property allow-list, so a patch
    /// naming it comes back `invalidPatch` with *nothing* applied.
    @Test("A draft patch never names from, mailboxIds or keywords")
    func patchCarriesOnlyDraftProperties() throws {
        let patch = try patch(
            DraftContent(to: [EmailAddress(name: nil, email: "a@x.test")], subject: "Hi"))

        #expect(patch["from"] == nil)
        #expect(patch["mailboxIds"] == nil)
        #expect(patch["keywords"] == nil)
    }

    /// The server reads the body through the part ids in `textBody`/`htmlBody`,
    /// so naming either without the values is a save that changes nothing.
    @Test("A body patch always carries bodyValues")
    func bodyValuesAccompanyTheBody() throws {
        let patch = try patch(DraftContent(text: "plain", html: "<div>rich</div>"))

        let values = try #require(patch["bodyValues"] as? [String: Any])
        let html = try #require(values["html"] as? [String: Any])

        #expect(html["value"] as? String == "<div>rich</div>")
        #expect(patch["htmlBody"] != nil)
        #expect(patch["textBody"] != nil)
    }

    @Test("Bcc reaches the wire, and a cleared list reaches it as null")
    func bccIsWritten() throws {
        let withBcc = try patch(
            DraftContent(bcc: [EmailAddress(name: nil, email: "secret@x.test")]))

        #expect((withBcc["bcc"] as? [[String: Any]])?.count == 1)

        let cleared = try patch(DraftContent())

        #expect(cleared["bcc"] is NSNull)
    }

    @Test("ifInState is sent when given, so two devices on one draft collide")
    func ifInState() throws {
        let method = DraftUpdate(
            accountID: AccountID("1"),
            emailID: EmailID("42"),
            content: DraftContent(),
            ifInState: StateToken(rawValue: "s7"))
        let json = try #require(
            try JSONSerialization.jsonObject(with: try JSONEncoder().encode(method.arguments))
                as? [String: Any])

        #expect(json["ifInState"] as? String == "s7")
    }

    @Test("A create carries no attachments key when there are none")
    func createOmitsEmptyAttachments() throws {
        let draft = EmailCreate.Draft(
            drafts: MailboxID("3"), content: DraftContent(subject: "Hi"))
        let json = try #require(
            try JSONSerialization.jsonObject(with: try JSONEncoder().encode(draft))
                as? [String: Any])

        #expect(json["attachments"] == nil)
    }
}
