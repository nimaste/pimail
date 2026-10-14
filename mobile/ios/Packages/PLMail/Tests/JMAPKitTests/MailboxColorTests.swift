import Foundation
import Testing

@testable import JMAPKit

/// Colour is the one label property that can be **cleared**, and the wire has
/// to say which of three things a client meant: leave it alone, set it, or take
/// it off. plMail treats every property mentioned in a patch as a change, so
/// the difference between an absent key and an explicit null is the difference
/// between a rename and a rename that also throws away a colour the user picked
/// in the web UI.
@Suite("Mailbox colour")
struct MailboxColorTests {
    private func encoded(_ method: MailboxSet) throws -> String {
        var builder = RequestBuilder()
        builder.add(method)

        return try String(decoding: builder.encoded(), as: UTF8.self)
    }

    // MARK: - The three states of a patch

    @Test("a rename leaves the colour alone by not mentioning it")
    func patchAbsent() throws {
        let json = try encoded(
            MailboxSet.rename(MailboxID("42"), to: "Receipts", accountID: AccountID("7")))

        #expect(json.contains("color") == false)
    }

    @Test("setting a colour sends the token")
    func patchSet() throws {
        let json = try encoded(
            MailboxSet.recolor(MailboxID("42"), to: .violet, accountID: AccountID("7")))

        #expect(json.contains("\"color\":\"violet\""))
        // And nothing else: a recolour that also carried a name would overwrite
        // whatever the web UI renamed the label to in the meantime.
        #expect(json.contains("\"name\"") == false)
        #expect(json.contains("parentId") == false)
    }

    @Test("clearing a colour sends an explicit null")
    func patchCleared() throws {
        let json = try encoded(
            MailboxSet.recolor(MailboxID("42"), to: nil, accountID: AccountID("7")))

        #expect(json.contains("\"color\":null"))
    }

    /// The failure the double optional exists to prevent, stated as one
    /// comparison: "clear it" and "leave it alone" must not encode alike.
    @Test("clearing and leaving alone are different requests")
    func clearedDiffersFromAbsent() throws {
        let cleared = try encoded(
            MailboxSet(
                accountID: AccountID("7"),
                update: [MailboxID("42"): MailboxSet.Patch(color: .some(nil))]))
        let absent = try encoded(
            MailboxSet(
                accountID: AccountID("7"), update: [MailboxID("42"): MailboxSet.Patch()]))

        #expect(cleared != absent)
        #expect(absent.contains("\"update\":{\"42\":{}}"))
    }

    /// Re-parenting and recolouring in one request would be two changes the
    /// server can refuse as one, so each helper touches exactly its own key.
    @Test("re-parenting does not disturb the colour")
    func reparentLeavesColourAlone() throws {
        let json = try encoded(
            MailboxSet.reparent(MailboxID("42"), to: MailboxID("13"), accountID: AccountID("7")))

        #expect(json.contains("\"parentId\":\"13\""))
        #expect(json.contains("color") == false)
    }

    // MARK: - Creating

    @Test("a create carries the colour token it was given")
    func createWithColour() throws {
        let json = try encoded(
            MailboxSet.create(name: "Invoices", color: .teal, accountID: AccountID("7")))

        #expect(json.contains("\"color\":\"teal\""))
    }

    /// A create has no third state to express — `MailboxSetMethod` reads it as
    /// `$properties['color'] ?? null`, so absent and null are the same request
    /// — and sending a key the user did not ask for is the habit that makes the
    /// update path dangerous.
    @Test("a colourless create does not mention colour")
    func createWithoutColour() throws {
        #expect(
            try encoded(MailboxSet.create(name: "Invoices", accountID: AccountID("7")))
                .contains("color") == false)
    }

    // MARK: - Reading

    @Test("a known token decodes to its case")
    func decodeKnownToken() throws {
        let mailbox = try JSONDecoder().decode(
            Mailbox.self, from: Data(#"{"id":"50","name":"Work","color":"amber"}"#.utf8))

        #expect(mailbox.color == .amber)
    }

    /// Null is "no colour chosen", a third state that is **not** grey: only it
    /// may fall back to a hashed tint, and a label deliberately coloured grey
    /// has to stay where the user put it.
    @Test("a null colour and a grey one are not the same value")
    func nullIsNotGrey() throws {
        let uncoloured = try JSONDecoder().decode(
            Mailbox.self, from: Data(#"{"id":"50","name":"Work","color":null}"#.utf8))
        let grey = try JSONDecoder().decode(
            Mailbox.self, from: Data(#"{"id":"51","name":"Home","color":"gray"}"#.utf8))

        #expect(uncoloured.color == nil)
        #expect(grey.color == .gray)
    }

    @Test("an omitted colour decodes as no colour rather than failing")
    func missingKey() throws {
        let mailbox = try JSONDecoder().decode(
            Mailbox.self, from: Data(#"{"id":"50","name":"Work"}"#.utf8))

        #expect(mailbox.color == nil)
    }

    /// The compatibility guarantee. A server that grows a tenth colour must not
    /// make older clients undecodable: a `Mailbox` that throws takes the whole
    /// `Mailbox/get` response with it, and the sidebar empties. Falling back to
    /// the hashed tint costs one wrong hue.
    @Test("a colour this build has never heard of is not an error")
    func unknownTokenFallsBack() throws {
        let mailbox = try JSONDecoder().decode(
            Mailbox.self,
            from: Data(#"{"id":"50","name":"Work","color":"chartreuse"}"#.utf8))

        #expect(mailbox.color == nil)
        #expect(mailbox.name == "Work")
    }

    @Test("one unknown colour does not take the rest of the response with it")
    func unknownTokenInAList() throws {
        let json = """
            {"accountId":"7","state":"m1","list":[
              {"id":"50","name":"Work","color":"chartreuse"},
              {"id":"51","name":"Home","color":"blue"}
            ],"notFound":[]}
            """

        let result = try JSONDecoder().decode(GetResult<Mailbox>.self, from: Data(json.utf8))

        #expect(result.list.count == 2)
        #expect(result.list.first?.color == nil)
        #expect(result.list.last?.color == .blue)
    }

    @Test("the vocabulary is exactly the nine tokens the server stores")
    func vocabulary() {
        #expect(
            LabelColor.allCases.map(\.rawValue) == [
                "gray", "red", "orange", "amber", "green", "teal", "blue", "violet", "pink",
            ])
        #expect(LabelColor(wire: nil) == nil)
        #expect(LabelColor(wire: "") == nil)
        // Case-sensitive, like the server's own `LabelColor::tryFrom`.
        #expect(LabelColor(wire: "Blue") == nil)
        #expect(LabelColor(wire: "blue") == .blue)
    }
}
