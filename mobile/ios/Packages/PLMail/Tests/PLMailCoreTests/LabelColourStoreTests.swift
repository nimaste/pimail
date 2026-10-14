import Foundation
import JMAPKit
import Testing

@testable import PLMailCore

/// Colour has to survive the round trip through the store.
///
/// `StoredMailbox.color` and `MailboxSnapshot.color` were both added before
/// anything filled them, which is the worst shape a feature can be in: the
/// wire decoded a colour, the schema had a column for it, every test passed,
/// and every label on screen read as *no colour chosen*. These tests assert the
/// two writes that close that gap, so deleting either one fails here rather
/// than in the sidebar.
@Suite("Label colour in the store")
struct LabelColourStoreTests {
    private func makeStore() -> SyncStore {
        SyncStore(modelContainer: MailStack.makeContainer(inMemory: true))
    }

    private func label(_ id: String, named name: String, color: LabelColor?) -> Mailbox {
        var mailbox = Mailbox(id: MailboxID(id))
        mailbox.name = name
        mailbox.labelID = LabelID(rawValue: "l-\(id)")
        mailbox.color = color

        return mailbox
    }

    @Test("a label's colour survives the trip through the store")
    func roundTrips() async throws {
        let store = makeStore()

        let snapshots = try await store.replaceMailboxes(
            [label("70", named: "Work", color: .violet)],
            accountKey: "srv/1", state: StateToken(rawValue: "1"))

        #expect(snapshots.first?.color == .violet)
    }

    /// Re-read rather than taken from the return value: `replaceMailboxes`
    /// builds its snapshots from the rows it has just written, so a test that
    /// only checks what it returned would pass even if nothing were persisted.
    @Test("the colour is on the row, not just on the value that was returned")
    func persists() async throws {
        let store = makeStore()

        try await store.replaceMailboxes(
            [label("70", named: "Work", color: .teal)],
            accountKey: "srv/1", state: StateToken(rawValue: "1"))

        let reread = try await store.mailboxes(accountKey: "srv/1")

        #expect(reread.first?.color == .teal)
    }

    /// Absent is a third state and not grey. Only nil may fall back to the
    /// hashed tint, so a label deliberately coloured grey has to come back as
    /// `.gray` — collapsing the two repaints every label somebody chose grey on
    /// purpose.
    @Test("no colour chosen and a colour of grey are not the same answer")
    func greyIsNotAbsent() async throws {
        let store = makeStore()

        let snapshots = try await store.replaceMailboxes(
            [
                label("70", named: "Plain", color: nil),
                label("71", named: "Grey", color: .gray),
            ],
            accountKey: "srv/1", state: StateToken(rawValue: "1"))

        let byName = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.name, $0.color) })

        #expect(byName["Plain"] == .some(nil))
        #expect(byName["Grey"] == .gray)
    }

    /// A colour cleared on the web has to clear here too. The write is a plain
    /// assignment rather than a `??`, and the difference only shows on the
    /// second sync: with a fallback, "no colour" would keep whatever the label
    /// was last coloured, forever.
    @Test("clearing a colour on the server clears it here")
    func clears() async throws {
        let store = makeStore()

        try await store.replaceMailboxes(
            [label("70", named: "Work", color: .red)],
            accountKey: "srv/1", state: StateToken(rawValue: "1"))

        let snapshots = try await store.replaceMailboxes(
            [label("70", named: "Work", color: nil)],
            accountKey: "srv/1", state: StateToken(rawValue: "2"))

        #expect(snapshots.first?.color == nil)
    }
}
