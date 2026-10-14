import Foundation
import Testing

@testable import JMAPKit

/// `Mailbox/set` is the one method here that can destroy structure the user
/// built, so its encoding is pinned rather than trusted.
@Suite("Mailbox/set encoding")
struct MailboxSetTests {
    private func encoded(_ method: MailboxSet) throws -> String {
        var builder = RequestBuilder()
        builder.add(method)

        return try String(decoding: builder.encoded(), as: UTF8.self)
    }

    @Test("a create carries the name under its creation id")
    func create() throws {
        let json = try encoded(MailboxSet.create(name: "Invoices", accountID: AccountID("7")))

        #expect(json.contains("\"create\":{\"new\":{\"name\":\"Invoices\"}}"))
        #expect(json.contains("\"accountId\":\"7\""))
    }

    /// Omitted, not null. plMail reads `parentId` with `?? null`, so either
    /// works for a top-level create — but sending a key the user did not ask
    /// for is how the update path goes wrong, and the two should not differ.
    @Test("a top-level create does not mention parentId")
    func createWithoutParent() throws {
        #expect(
            try encoded(MailboxSet.create(name: "Invoices", accountID: AccountID("7")))
                .contains("parentId") == false)
    }

    @Test("a nested create names its parent binding")
    func createWithParent() throws {
        #expect(
            try encoded(
                MailboxSet.create(
                    name: "Invoices", parentID: MailboxID("13"), accountID: AccountID("7"))
            ).contains("\"parentId\":\"13\""))
    }

    /// The bug this type exists to prevent. plMail treats every property
    /// *mentioned* in a patch as a change, so a rename that also carried
    /// `parentId: null` would move the label to the top level — silently
    /// flattening a hierarchy the user never touched.
    @Test("a rename does not mention parentId")
    func renameLeavesTheParentAlone() throws {
        let json = try encoded(
            MailboxSet.rename(MailboxID("42"), to: "Receipts", accountID: AccountID("7")))

        #expect(json.contains("\"update\":{\"42\":{\"name\":\"Receipts\"}}"))
        #expect(json.contains("parentId") == false)
    }

    /// The other half of the same distinction: clearing the parent has to be
    /// expressible, and it is an explicit null rather than an absent key.
    @Test("moving a label to the top level sends an explicit null")
    func explicitNullParent() throws {
        let json = try encoded(
            MailboxSet(
                accountID: AccountID("7"),
                update: [MailboxID("42"): MailboxSet.Patch(parentID: .some(nil))]
            ))

        #expect(json.contains("\"parentId\":null"))
        #expect(json.contains("name") == false)
    }

    @Test("a destroy is a bare array of ids")
    func destroy() throws {
        #expect(
            try encoded(MailboxSet.destroy(MailboxID("42"), accountID: AccountID("7")))
                .contains("\"destroy\":[\"42\"]"))
    }

    /// An empty patch is a request that changes nothing; it must not acquire
    /// keys from the encoder.
    @Test("an empty patch encodes as an empty object")
    func emptyPatch() throws {
        #expect(
            try encoded(
                MailboxSet(
                    accountID: AccountID("7"), update: [MailboxID("42"): MailboxSet.Patch()])
            ).contains("\"update\":{\"42\":{}}"))
    }

    @Test("a created mailbox decodes with the id the server assigned")
    func decodeCreated() throws {
        let json = """
            {"accountId":"7","oldState":"m1","newState":"m2",
             "created":{"new":{"id":"501","labelId":"9501","role":null,"sortOrder":0}},
             "notCreated":{},"updated":{},"notUpdated":{},
             "destroyed":[],"notDestroyed":{}}
            """

        let result = try JSONDecoder().decode(
            MailboxSet.Result.self, from: Data(json.utf8))

        #expect(result.created?[MailboxSet.creationID]?.id == MailboxID("501"))
        #expect(result.created?[MailboxSet.creationID]?.labelID == LabelID("9501"))
        #expect(result.newState == StateToken(rawValue: "m2"))
    }

    /// A 200 carrying a refusal is the shape a client is most likely to read
    /// as success.
    @Test("a refused destroy decodes into notDestroyed")
    func decodeNotDestroyed() throws {
        let json = """
            {"accountId":"7","created":{},"notCreated":{},"updated":{},"notUpdated":{},
             "destroyed":[],"notDestroyed":{"42":{"type":"mailboxHasChild"}}}
            """

        let result = try JSONDecoder().decode(MailboxSet.Result.self, from: Data(json.utf8))

        #expect(result.destroyed?.isEmpty == true)
        #expect(
            result.notDestroyed?[MailboxID("42")]?.objectValue?["type"]?.stringValue
                == "mailboxHasChild")
    }
}
