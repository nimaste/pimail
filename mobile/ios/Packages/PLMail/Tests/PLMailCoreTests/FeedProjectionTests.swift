import Foundation
import JMAPKit
import Testing

@testable import PLMailCore

/// Keeping every cached list correct, not only the one on screen.
///
/// The failure this prevents is invisible until it is reported as "the app
/// ignored what I did in the browser": delta sync updates objects and stops, so
/// a conversation archived on the web stays in the iOS inbox sixty rows down,
/// and a conversation labelled `Work` never joins the `Work` list until that
/// list is re-paged.
@Suite("Feed projection")
struct FeedProjectionTests {
    private let inbox = MailboxSnapshot(
        accountKey: "srv/1", mailboxID: MailboxID("70"), labelID: nil, name: "Inbox",
        role: .inbox, parentID: nil, color: nil, unreadThreads: 0, totalThreads: 0)

    private let work = MailboxSnapshot(
        accountKey: "srv/1", mailboxID: MailboxID("73"), labelID: LabelID("lbl-work"),
        name: "Work", role: nil, parentID: nil, color: nil, unreadThreads: 0, totalThreads: 0)

    private var mailboxes: [MailboxSnapshot] { [inbox, work] }

    // MARK: - Membership

    @Test("a conversation in the Inbox binding belongs in the unified inbox")
    func belongsByRole() {
        #expect(
            FeedProjection.belongs(
                in: .unified(.inbox), mailboxIDs: ["70"], accountKey: "srv/1",
                mailboxes: mailboxes) == true)

        #expect(
            FeedProjection.belongs(
                in: .unified(.inbox), mailboxIDs: ["73"], accountKey: "srv/1",
                mailboxes: mailboxes) == false)
    }

    /// One label spans every account and is a different binding in each, which
    /// is why the feed names the user-scoped id and the membership test has to
    /// resolve it per account.
    @Test("a label feed resolves this account's binding")
    func belongsByLabel() {
        #expect(
            FeedProjection.belongs(
                in: .unifiedLabel(LabelID("lbl-work")), mailboxIDs: ["73"],
                accountKey: "srv/1", mailboxes: mailboxes) == true)
    }

    /// Nil is "leave alone", not "remove". An account with no binding for a
    /// role contributes no rows to that list and never did, and treating the
    /// unanswerable question as a "no" is how a projection empties lists it does
    /// not understand.
    @Test("an unanswerable question leaves the list alone")
    func unanswerable() {
        #expect(
            FeedProjection.belongs(
                in: .unified(.archive), mailboxIDs: ["70"], accountKey: "srv/1",
                mailboxes: mailboxes) == nil)

        #expect(
            FeedProjection.belongs(
                in: .mailbox(accountKey: "srv/2", mailboxID: MailboxID("70")),
                mailboxIDs: ["70"], accountKey: "srv/1", mailboxes: mailboxes) == nil)
    }

    /// Rows in a search feed answer a question, not a state: a conversation
    /// that gains a label does not thereby match a search for "invoice".
    @Test("search results are never projected into")
    func neverSearch() {
        #expect(
            FeedProjection.belongs(
                in: .searchResults(query: "invoice"), mailboxIDs: ["70"], accountKey: "srv/1",
                mailboxes: mailboxes) == nil)
    }

    // MARK: - The paged window

    /// A conversation from 2019 dragged back by a read receipt must not be
    /// spliced in under last week's mail: the list has never paged that far, so
    /// the row would sit above hundreds of messages newer than it.
    @Test("a row older than the deepest page is not spliced in")
    func window() {
        let cursor = FeedCursorSnapshot(
            lastSortDate: Date(timeIntervalSince1970: 1_700_000_000),
            boundaryIDs: [],
            isExhausted: false
        )

        #expect(
            FeedProjection.isWithinWindow(
                Date(timeIntervalSince1970: 1_700_000_001), cursor: cursor))
        #expect(
            FeedProjection.isWithinWindow(
                Date(timeIntervalSince1970: 1_600_000_000), cursor: cursor) == false)
    }

    @Test("a list that has reached its end accepts any row")
    func exhaustedWindow() {
        let cursor = FeedCursorSnapshot(
            lastSortDate: Date(timeIntervalSince1970: 1_700_000_000),
            boundaryIDs: [],
            isExhausted: true
        )

        #expect(
            FeedProjection.isWithinWindow(
                Date(timeIntervalSince1970: 1_000_000_000), cursor: cursor))
    }

    /// Splicing into a list nothing has ever paged would show a single row and
    /// imply that is all there is.
    @Test("a list nothing has paged yet is not spliced into")
    func unpagedWindow() {
        #expect(
            FeedProjection.isWithinWindow(.now, cursor: FeedCursorSnapshot()) == false)
    }

    // MARK: - Reconciliation

    private var feeds: [(feed: FeedID, cursor: FeedCursorSnapshot)] {
        [
            (
                .unified(.inbox),
                FeedCursorSnapshot(
                    lastSortDate: Date(timeIntervalSince1970: 1_000_000_000),
                    boundaryIDs: [], isExhausted: false)
            ),
            (
                .unifiedLabel(LabelID("lbl-work")),
                FeedCursorSnapshot(
                    lastSortDate: Date(timeIntervalSince1970: 1_000_000_000),
                    boundaryIDs: [], isExhausted: false)
            ),
        ]
    }

    @Test("archiving elsewhere removes the row from the inbox and adds it to its label")
    func reconciles() {
        let changes = FeedProjection.changes(
            threadID: "t1",
            accountKey: "srv/1",
            mailboxIDs: ["73"],
            sortDate: Date(timeIntervalSince1970: 1_700_000_000),
            newestEmailID: "e1",
            feeds: feeds,
            mailboxes: mailboxes,
            pendingTargets: []
        )

        #expect(
            changes.contains {
                $0.feedID == FeedID.unified(.inbox).rawValue && $0.kind == .remove
            })
        #expect(
            changes.contains {
                $0.feedID == FeedID.unifiedLabel(LabelID("lbl-work")).rawValue
                    && $0.kind
                        == .insert(
                            sortDate: Date(timeIntervalSince1970: 1_700_000_000), emailID: "e1")
            })
    }

    /// The seam between the offline queue and the projection. The server still
    /// says the conversation is in the Inbox, because it has not been told
    /// otherwise — projecting that answer puts the row the user archived on a
    /// train back on screen, and the gesture looks ignored.
    @Test("a conversation the queue has an opinion about is left alone")
    func pendingTargetsWin() {
        let changes = FeedProjection.changes(
            threadID: "t1",
            accountKey: "srv/1",
            mailboxIDs: ["70"],
            sortDate: Date(timeIntervalSince1970: 1_700_000_000),
            newestEmailID: "e1",
            feeds: feeds,
            mailboxes: mailboxes,
            pendingTargets: ["srv/1#t1"]
        )

        #expect(changes.isEmpty)
    }

    // MARK: - Feed ids

    /// The projection reads the feeds an account has paged out of a table of
    /// raw strings, so a `FeedID` that cannot be read back is a list that can
    /// never be reconciled.
    @Test(
        "every feed id survives the round trip through its raw value",
        arguments: [
            FeedID.unified(.inbox),
            FeedID.unified(.other("newsletters")),
            FeedID.unifiedLabel(LabelID("lbl-work")),
            FeedID.mailbox(accountKey: "nas.local:8443/1", mailboxID: MailboxID("70")),
            FeedID.searchResults(query: "invoice from:ada"),
        ])
    func feedIDRoundTrip(feed: FeedID) throws {
        #expect(FeedID(rawValue: feed.rawValue) == feed)
    }

    @Test("a raw value from nowhere in particular is refused rather than guessed at")
    func feedIDRejectsNonsense() {
        #expect(FeedID(rawValue: "who knows") == nil)
        #expect(FeedID(rawValue: "acct:srv/1") == nil)
    }
}
