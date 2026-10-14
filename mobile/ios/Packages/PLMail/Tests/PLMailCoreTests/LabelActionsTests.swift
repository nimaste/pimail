import Foundation
import JMAPKit
import JMAPTestSupport
import Testing

@testable import PLMailCore

/// Creating, renaming and deleting labels.
///
/// The failure worth guarding is the same one `Identity/set` has: `Mailbox/set`
/// answers **200 with the refusal inside the body**. A client that reads the
/// HTTP status as the answer shows a label as created that the server threw
/// away — and then sends its id with the next message the user labels.
@Suite("Label actions")
@MainActor
struct LabelActionsTests {
    private let accountID = AccountID("1")

    private func makeActions(
        _ server: FakeMailServer
    ) -> (LabelActions, refreshCount: () -> Int) {
        let refreshes = Counter()
        let actions = LabelActions(client: server.makeClient()) { refreshes.bump() }

        return (actions, { refreshes.value })
    }

    /// A class rather than a captured var: the closure is `@Sendable` and has
    /// to be able to record into something the test can read afterwards.
    @MainActor
    private final class Counter {
        private(set) var value = 0
        func bump() { value += 1 }
    }

    // MARK: - Creating

    @Test("a create returns the id the server assigned")
    func creates() async throws {
        let server = FakeMailServer(accounts: ["1": []])
        let (actions, refreshCount) = makeActions(server)

        let id = await actions.create(named: "Invoices", accountID: accountID)

        #expect(id != nil)
        #expect(server.labels(accountID: "1").map(\.name) == ["Invoices"])
        #expect(actions.failure == nil)
        // Nothing else in the app would know the label exists otherwise.
        #expect(refreshCount() == 1)
    }

    /// Asserted against what the *wire* carried, not against what the server
    /// stored. plMail trims too, so checking the stored name passes whether or
    /// not this client trims anything — a test that proves the server works.
    @Test("surrounding whitespace is trimmed before the name is sent")
    func trims() async throws {
        let server = FakeMailServer(accounts: ["1": []])
        let (actions, _) = makeActions(server)

        await actions.create(named: "  Invoices  ", accountID: accountID)

        #expect(server.receivedLabelNames == ["Invoices"])
        #expect(server.labels(accountID: "1").map(\.name) == ["Invoices"])
    }

    /// Caught locally, so the answer is instant and identical to the server's.
    /// Nothing must reach the wire — a refused round trip is a round trip.
    @Test("a name with a slash is refused before it is sent")
    func refusesSlash() async throws {
        let server = FakeMailServer(accounts: ["1": []])
        let (actions, refreshCount) = makeActions(server)

        let id = await actions.create(named: "Work/Invoices", accountID: accountID)

        #expect(id == nil)
        #expect(actions.failure != nil)
        #expect(server.labels(accountID: "1").isEmpty)
        #expect(refreshCount() == 0)
    }

    @Test("an empty name is refused before it is sent")
    func refusesEmpty() async throws {
        let server = FakeMailServer(accounts: ["1": []])
        let (actions, _) = makeActions(server)

        #expect(await actions.create(named: "   ", accountID: accountID) == nil)
        #expect(actions.failure != nil)
        #expect(server.labels(accountID: "1").isEmpty)
    }

    /// The 200-with-a-refusal case. The name is legal locally, so this can only
    /// be discovered from the body.
    @Test("a duplicate sibling is reported, not silently dropped")
    func reportsDuplicate() async throws {
        let server = FakeMailServer(accounts: ["1": []])
        let (actions, refreshCount) = makeActions(server)

        await actions.create(named: "Invoices", accountID: accountID)
        let second = await actions.create(named: "Invoices", accountID: accountID)

        #expect(second == nil)
        #expect(actions.failure != nil)
        #expect(server.labels(accountID: "1").count == 1)
        // One refresh for the create that worked, none for the one that did not.
        #expect(refreshCount() == 1)
    }

    /// The complaint has to be the *specific* one. A refusal read only as
    /// "nothing came back" degrades to the generic message, which tells the
    /// user to try again at something that will never work. Compared against
    /// the generic text rather than pinned to a literal, so the assertion
    /// survives a rewording of either.
    @Test("a duplicate says so, rather than falling back to the generic error")
    func duplicateComplaintIsSpecific() async throws {
        let server = FakeMailServer(accounts: ["1": []])
        let (actions, _) = makeActions(server)

        await actions.create(named: "Invoices", accountID: accountID)
        await actions.create(named: "Invoices", accountID: accountID)

        let duplicate = try #require(actions.failure)
        let generic = await Self.genericFailure(server)

        #expect(generic != nil)
        #expect(duplicate != generic)
    }

    /// What a server that answers 200 and does nothing produces. Derived
    /// rather than written down, so it cannot drift from the real string.
    private static func genericFailure(_ server: FakeMailServer) async -> String? {
        server.setSilentlyIgnoresMailboxSet(true)
        defer { server.setSilentlyIgnoresMailboxSet(false) }

        let actions = LabelActions(client: server.makeClient()) {}
        await actions.create(named: "Anything", accountID: AccountID("1"))

        return actions.failure
    }

    /// Neither done nor refused. `destroyed` is the only proof a delete
    /// happened, and treating "no refusal" as success takes the label out of
    /// the sidebar while it is still on the server.
    @Test("a server that answers 200 and does nothing is not read as success")
    func silentServerIsNotSuccess() async throws {
        let server = FakeMailServer(accounts: ["1": []])
        server.setLabels(
            [FakeMailServer.CustomLabel(id: "50", labelID: "950", name: "Invoices")],
            accountID: "1")
        server.setSilentlyIgnoresMailboxSet(true)
        let (actions, refreshCount) = makeActions(server)

        #expect(await actions.delete(MailboxID("50"), accountID: accountID) == false)
        #expect(actions.failure != nil)
        #expect(refreshCount() == 0)

        #expect(await actions.create(named: "Receipts", accountID: accountID) == nil)
        #expect(await actions.rename(MailboxID("50"), to: "X", accountID: accountID) == false)
    }

    // MARK: - Renaming

    @Test("a rename reaches the server")
    func renames() async throws {
        let server = FakeMailServer(accounts: ["1": []])
        server.setLabels(
            [FakeMailServer.CustomLabel(id: "50", labelID: "950", name: "Invoices")],
            accountID: "1")
        let (actions, _) = makeActions(server)

        #expect(await actions.rename(MailboxID("50"), to: "Receipts", accountID: accountID))
        #expect(server.labels(accountID: "1").map(\.name) == ["Receipts"])
    }

    /// The whole point of the double-optional patch: a rename must not move the
    /// label. If `parentId: null` were sent alongside the name, this nested
    /// label would silently become a top-level one.
    @Test("a rename leaves the parent where it was")
    func renameKeepsParent() async throws {
        let server = FakeMailServer(accounts: ["1": []])
        server.setLabels(
            [
                FakeMailServer.CustomLabel(id: "50", labelID: "950", name: "Work"),
                FakeMailServer.CustomLabel(
                    id: "51", labelID: "951", name: "Invoices", parentID: "50"),
            ],
            accountID: "1")
        let (actions, _) = makeActions(server)

        #expect(await actions.rename(MailboxID("51"), to: "Receipts", accountID: accountID))

        let renamed = try #require(server.labels(accountID: "1").first { $0.id == "51" })

        #expect(renamed.name == "Receipts")
        #expect(renamed.parentID == "50")
    }

    @Test("renaming a system mailbox is refused and reported")
    func refusesSystemRename() async throws {
        let server = FakeMailServer(accounts: ["1": []])
        let (actions, _) = makeActions(server)

        // "1" is the fake's Inbox, whose myRights say mayRename: false.
        #expect(await actions.rename(MailboxID("1"), to: "Nope", accountID: accountID) == false)
        #expect(actions.failure != nil)
    }

    // MARK: - Deleting

    @Test("a delete removes the label")
    func deletes() async throws {
        let server = FakeMailServer(accounts: ["1": []])
        server.setLabels(
            [FakeMailServer.CustomLabel(id: "50", labelID: "950", name: "Invoices")],
            accountID: "1")
        let (actions, _) = makeActions(server)

        #expect(await actions.delete(MailboxID("50"), accountID: accountID))
        #expect(server.labels(accountID: "1").isEmpty)
    }

    /// A parent with children comes back 200 with an empty `destroyed` array.
    /// Trusting the status here would take the label out of the sidebar while
    /// it was still on the server.
    @Test("deleting a label with children is refused and reported")
    func refusesDeleteWithChildren() async throws {
        let server = FakeMailServer(accounts: ["1": []])
        server.setLabels(
            [
                FakeMailServer.CustomLabel(id: "50", labelID: "950", name: "Work"),
                FakeMailServer.CustomLabel(
                    id: "51", labelID: "951", name: "Invoices", parentID: "50"),
            ],
            accountID: "1")
        let (actions, refreshCount) = makeActions(server)

        #expect(await actions.delete(MailboxID("50"), accountID: accountID) == false)
        #expect(server.labels(accountID: "1").count == 2)
        #expect(refreshCount() == 0)

        // "Delete the nested ones first" is an instruction; the generic
        // message tells the user to retry something that cannot work.
        let refusal = try #require(actions.failure)
        let generic = await Self.genericFailure(server)

        #expect(generic != nil)
        #expect(refusal != generic)
    }

    @Test("a refused rename says why, rather than falling back to the generic error")
    func renameRefusalIsSpecific() async throws {
        let server = FakeMailServer(accounts: ["1": []])
        let (actions, _) = makeActions(server)

        // The fake's Inbox, whose myRights say mayRename: false.
        #expect(await actions.rename(MailboxID("1"), to: "Nope", accountID: accountID) == false)

        let refusal = try #require(actions.failure)
        let generic = await Self.genericFailure(server)

        #expect(generic != nil)
        #expect(refusal != generic)
    }

    @Test("deleting a system mailbox is refused")
    func refusesSystemDelete() async throws {
        let server = FakeMailServer(accounts: ["1": []])
        let (actions, _) = makeActions(server)

        #expect(await actions.delete(MailboxID("1"), accountID: accountID) == false)
        #expect(actions.failure != nil)
    }

    // MARK: - Failure handling

    @Test("an unreachable server is reported and changes nothing")
    func reportsUnreachable() async throws {
        let server = FakeMailServer(accounts: ["1": []])
        server.setFailing(true, accountID: "1")
        let (actions, refreshCount) = makeActions(server)

        #expect(await actions.create(named: "Invoices", accountID: accountID) == nil)
        #expect(actions.failure != nil)
        #expect(refreshCount() == 0)
    }

    @Test("a new attempt clears the previous complaint")
    func clearsFailure() async throws {
        let server = FakeMailServer(accounts: ["1": []])
        let (actions, _) = makeActions(server)

        await actions.create(named: "Work/Invoices", accountID: accountID)
        #expect(actions.failure != nil)

        await actions.create(named: "Invoices", accountID: accountID)
        #expect(actions.failure == nil)
    }

    // MARK: - Name rules

    @Test("the complaint names the rule, and is silent about a good name")
    func complaints() {
        #expect(LabelActions.complaint(about: "Invoices") == nil)
        #expect(LabelActions.complaint(about: "  Invoices  ") == nil)
        #expect(LabelActions.complaint(about: "") != nil)
        #expect(LabelActions.complaint(about: "   ") != nil)
        #expect(LabelActions.complaint(about: "Work/Invoices") != nil)
    }

    @Test("a duplicate is spotted per parent and per account, ignoring case")
    func duplicateDetection() {
        let mailboxes = [
            MailboxSnapshot(
                accountKey: "a", mailboxID: MailboxID("50"), labelID: LabelID("950"),
                name: "Work", role: nil, parentID: nil, unreadThreads: 0, totalThreads: 0),
            MailboxSnapshot(
                accountKey: "a", mailboxID: MailboxID("51"), labelID: LabelID("951"),
                name: "Invoices", role: nil, parentID: MailboxID("50"), unreadThreads: 0,
                totalThreads: 0),
        ]

        func taken(_ name: String, parentID: MailboxID?, accountKey: String = "a") -> Bool {
            LabelActions.nameIsTaken(
                name, parentID: parentID, accountKey: accountKey, among: mailboxes)
        }

        #expect(taken("Work", parentID: nil))
        #expect(taken("work", parentID: nil))
        // Same name, different parent — a legal sibling pair, not a duplicate.
        #expect(taken("Invoices", parentID: nil) == false)
        #expect(taken("Invoices", parentID: MailboxID("50")))
        // Labels are per-account bindings, so another account is not a clash.
        #expect(taken("Work", parentID: nil, accountKey: "b") == false)
        // An empty name is the empty-name complaint's job, not this one's.
        #expect(taken("", parentID: nil) == false)
    }
}
