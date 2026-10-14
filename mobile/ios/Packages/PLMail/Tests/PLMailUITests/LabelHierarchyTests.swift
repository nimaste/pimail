import JMAPKit
import Testing

@testable import PLMailCore
@testable import PLMailUI

/// The wire carries a **leaf** name and a `parentId`, and nothing else. Draw
/// the leaf alone and two labels called `Q1` — one under `Work`, one under
/// `Personal` — are two identical rows in the sidebar and two identical
/// checkboxes in the picker, with no way to tell which one a tap will apply.
@Suite("Label hierarchy")
struct LabelHierarchyTests {
    private func mailbox(
        _ id: String, _ name: String, parent: String? = nil, account: String = "a"
    ) -> MailboxSnapshot {
        MailboxSnapshot(
            accountKey: account,
            mailboxID: MailboxID(id),
            labelID: LabelID("9" + id),
            name: name,
            role: nil,
            parentID: parent.map(MailboxID.init(rawValue:)),
            unreadThreads: 0,
            totalThreads: 0)
    }

    @Test("a top-level label is its own whole path")
    func topLevel() {
        let work = mailbox("1", "Work")
        let hierarchy = LabelHierarchy([work])

        #expect(hierarchy.path(for: work) == "Work")
        #expect(hierarchy.parentPath(for: work) == nil)
        #expect(hierarchy.spokenPath(for: work) == "Work")
        #expect(hierarchy.hasNesting == false)
    }

    @Test("a nested label reads outermost first")
    func nested() {
        let work = mailbox("1", "Work")
        let invoices = mailbox("2", "Invoices", parent: "1")
        let q1 = mailbox("3", "Q1", parent: "2")
        let hierarchy = LabelHierarchy([work, invoices, q1])

        #expect(hierarchy.path(for: q1) == "Work / Invoices / Q1")
        #expect(hierarchy.parentPath(for: q1) == "Work / Invoices")
        #expect(hierarchy.hasNesting)
    }

    /// The whole point, in one assertion.
    @Test("two labels with the same leaf name are told apart by their paths")
    func sameLeafDifferentParents() {
        let work = mailbox("1", "Work")
        let personal = mailbox("2", "Personal")
        let workQ1 = mailbox("3", "Q1", parent: "1")
        let personalQ1 = mailbox("4", "Q1", parent: "2")
        let hierarchy = LabelHierarchy([work, personal, workQ1, personalQ1])

        #expect(hierarchy.path(for: workQ1) != hierarchy.path(for: personalQ1))
        #expect(hierarchy.spokenPath(for: workQ1) != hierarchy.spokenPath(for: personalQ1))
    }

    /// `MailboxSetMethod::requireName` refuses a slash in a name, so a name
    /// carrying one arrived from an import or from before that rule — and with
    /// a bare `/` joiner it would read as a level of nesting that does not
    /// exist. The spaced separator keeps the two distinguishable, and the
    /// components are never re-split.
    @Test("a name containing the separator does not invent a level")
    func nameContainingSeparator() {
        let work = mailbox("1", "Work")
        let odd = mailbox("2", "Q1/Q2", parent: "1")
        let hierarchy = LabelHierarchy([work, odd])

        #expect(hierarchy.components(for: odd) == ["Work", "Q1/Q2"])
        #expect(hierarchy.path(for: odd) == "Work / Q1/Q2")
        #expect(hierarchy.parentPath(for: odd) == "Work")
        // Re-splitting on the drawn separator is what a caller must not do; the
        // path has two components and the string has three slash-separated
        // pieces, which is exactly why components(for:) is the public shape.
        #expect(hierarchy.path(for: odd).split(separator: "/").count == 3)
    }

    /// A parent the account has no binding for is reported by the server as
    /// no parent at all, so there is nothing to name.
    @Test("a parent with no binding here stops the walk")
    func missingParent() {
        let orphan = mailbox("2", "Invoices", parent: "999")
        let hierarchy = LabelHierarchy([orphan])

        #expect(hierarchy.path(for: orphan) == "Invoices")
        #expect(hierarchy.parentPath(for: orphan) == nil)
        #expect(hierarchy.hasNesting == false)
    }

    /// A client sees one account's slice of a user-scoped tree and cannot rule
    /// out a cycle. Without the guard this walk never returns.
    @Test("a parent cycle terminates instead of hanging")
    func cycle() {
        let first = mailbox("1", "A", parent: "2")
        let second = mailbox("2", "B", parent: "1")
        let hierarchy = LabelHierarchy([first, second])

        #expect(hierarchy.components(for: first).isEmpty == false)
        #expect(hierarchy.components(for: first).count <= LabelHierarchy.maxDepth + 1)
    }

    /// Unlimited depth server-side, so the client needs a stopping point — and
    /// one that says it stopped, rather than claiming a top-level ancestor the
    /// label does not have.
    @Test("a path deeper than the guard is marked as truncated")
    func truncation() {
        var mailboxes = [mailbox("0", "L0")]

        for level in 1...12 {
            mailboxes.append(mailbox("\(level)", "L\(level)", parent: "\(level - 1)"))
        }

        let hierarchy = LabelHierarchy(mailboxes)
        let path = hierarchy.components(for: mailboxes[12])

        #expect(path.count == LabelHierarchy.maxDepth + 1)
        #expect(path.first == LabelHierarchy.truncationMark)
        #expect(path.last == "L12")
    }

    // MARK: - Parent picking

    @Test("a label is its own descendant, so it cannot become its own parent")
    func selfIsDescendant() {
        let work = mailbox("1", "Work")
        let hierarchy = LabelHierarchy([work])

        #expect(hierarchy.isDescendant(work, of: MailboxID("1")))
    }

    @Test("a child cannot become its parent's parent")
    func descendantsAreRefused() {
        let work = mailbox("1", "Work")
        let invoices = mailbox("2", "Invoices", parent: "1")
        let q1 = mailbox("3", "Q1", parent: "2")
        let personal = mailbox("4", "Personal")
        let hierarchy = LabelHierarchy([work, invoices, q1, personal])

        #expect(hierarchy.isDescendant(q1, of: MailboxID("1")))
        #expect(hierarchy.isDescendant(personal, of: MailboxID("1")) == false)
    }

    // MARK: - Chips

    @Test("chips cover a conversation's custom labels and none of its roles")
    func chipModels() {
        var inbox = mailbox("9", "Inbox")
        inbox.role = .inbox
        let work = mailbox("1", "Work")
        var invoices = mailbox("2", "Invoices", parent: "1")
        invoices.color = .teal
        let mailboxes = [inbox, work, invoices]

        let chips = LabelChipModel.chips(
            forMailboxIDs: ["9", "2"],
            accountKey: "a",
            mailboxes: mailboxes,
            hierarchy: LabelHierarchy(mailboxes))

        #expect(chips.map(\.name) == ["Invoices"])
        #expect(chips.first?.color == .teal)
        // The path, not the leaf, is what the chip is read out as.
        #expect(chips.first?.path.contains("Work") == true)
        // Seeded on the user-scoped id so the fallback tint survives the same
        // label being reached through another account's binding.
        #expect(chips.first?.seed == "92")
    }

    /// A binding id is per-account. Matching one against another account's
    /// mailboxes is how a row grows a label it does not carry.
    @Test("a chip lookup stays inside the conversation's own account")
    func chipsAreAccountScoped() {
        let mine = mailbox("1", "Work", account: "a")
        let theirs = mailbox("1", "Work", account: "b")

        let chips = LabelChipModel.chips(
            forMailboxIDs: ["1"],
            accountKey: "b",
            mailboxes: [mine, theirs],
            hierarchy: LabelHierarchy([mine]))

        #expect(chips.count == 1)
    }

    /// Keyed on the pane, not the size class: the iPad list column is
    /// 396–540pt, so a size-class test answers the same at both ends.
    @Test("a narrow pane shows one chip and a wide one shows two")
    func chipSlots() {
        #expect(LabelChipBudget.slots(paneWidth: 390) == 1)
        #expect(LabelChipBudget.slots(paneWidth: 420) == 2)
    }
}
