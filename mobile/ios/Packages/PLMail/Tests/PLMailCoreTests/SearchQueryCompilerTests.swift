import Foundation
import JMAPKit
import Testing

@testable import PLMailCore

/// The compiler turns what a person typed into what the server is asked. A
/// mistake here does not error — it returns the wrong mail, quietly — so the
/// mapping is asserted on the encoded request rather than on intermediate
/// structures.
@Suite("Search query compilation")
struct SearchQueryCompilerTests {
    private let inbox = MailboxID("42")

    // MARK: - Conditions

    @Test("each operator maps to the condition the server compiles")
    func operatorMapping() throws {
        let query = SearchQuery.parse(
            "from:acme to:ops subject:invoice has:attachment is:unread is:starred overdue")

        let filter = try #require(SearchQueryCompiler.filter(for: query, mailboxID: nil))

        #expect(
            try encoded(filter) == """
                {"conditions":[{"from":"acme"},{"to":"ops"},{"subject":"invoice"},\
                {"hasAttachment":true},{"notKeyword":"$seen"},{"hasKeyword":"$flagged"},\
                {"text":"overdue"}],"operator":"AND"}
                """
        )
    }

    /// `in:` names a role, and a role is a different mailbox id in every
    /// account — so the id is supplied per account rather than baked in.
    @Test("in: becomes an inMailbox on the account's own binding id")
    func mailboxCondition() throws {
        let query = SearchQuery.parse("in:inbox urgent")
        let filter = try #require(SearchQueryCompiler.filter(for: query, mailboxID: inbox))

        #expect(
            try encoded(filter) == """
                {"conditions":[{"inMailbox":"42"},{"text":"urgent"}],"operator":"AND"}
                """
        )
    }

    /// A single condition is sent alone rather than wrapped in a one-element
    /// AND. Equivalent, but it keeps the request readable in a log.
    @Test("a lone condition is not wrapped in an operator")
    func singleCondition() throws {
        let filter = try #require(
            SearchQueryCompiler.filter(for: SearchQuery.parse("is:starred"), mailboxID: nil))

        #expect(try encoded(filter) == #"{"hasKeyword":"$flagged"}"#)
    }

    /// Nil rather than a filter that matches everything: a query that narrows
    /// nothing must not page an entire mailbox and call it results.
    @Test("a query that narrows nothing compiles to no filter")
    func emptyQuery() {
        #expect(SearchQueryCompiler.filter(for: SearchQuery.parse(""), mailboxID: nil) == nil)
        #expect(SearchQueryCompiler.filter(for: SearchQuery.parse("from:"), mailboxID: nil) == nil)
    }

    /// Contradictory on purpose — both clients return nothing for it, which is
    /// better than the two disagreeing.
    @Test("is:unread is:read compiles to a contradiction, as it does server-side")
    func contradiction() throws {
        let filter = try #require(
            SearchQueryCompiler.filter(for: SearchQuery.parse("is:unread is:read"), mailboxID: nil))

        let json = try encoded(filter)

        #expect(json.contains(#"{"notKeyword":"$seen"}"#))
        #expect(json.contains(#"{"hasKeyword":"$seen"}"#))
    }

    /// A typed date means *that day where the user is*, so it is parsed at
    /// local midnight and sent as the corresponding UTC instant. West of UTC
    /// that lands on the previous calendar day on the wire, which is correct —
    /// asserting the string would be asserting the reader's timezone.
    ///
    /// Note this can differ by an offset from the web UI, which parses in the
    /// *server's* timezone. That is ambiguous server-side too: the same query
    /// from the same person means different things depending on where their
    /// NAS thinks it is. Local midnight is the reading that matches intent.
    @Test("dates are bounded at the user's local midnight")
    func dateBounds() throws {
        let query = SearchQuery.parse("after:2024-01-01 before:2024-12-31")

        let after = try #require(query.after)
        let before = try #require(query.before)
        let calendar = Calendar.current

        #expect(calendar.startOfDay(for: after) == after)
        #expect(calendar.component(.year, from: after) == 2024)
        #expect(calendar.component(.month, from: after) == 1)
        #expect(calendar.component(.day, from: after) == 1)
        #expect(calendar.component(.day, from: before) == 31)

        // Both bounds reach the request; `after` is inclusive and `before`
        // strict, matching EmailFilterCompiler.
        let json = try encoded(#require(SearchQueryCompiler.filter(for: query, mailboxID: nil)))

        #expect(json.contains("\"after\":"))
        #expect(json.contains("\"before\":"))
    }

    // MARK: - Per-account applicability

    /// An account with no Archive binding cannot answer `in:archive`. Skipping
    /// it is right; including it unfiltered would return that account's whole
    /// mailbox as "results".
    @Test("an account without the requested role is excluded from the search")
    func roleMissing() {
        let query = SearchQuery.parse("in:archive report")

        let withArchive = [mailbox(role: .archive, id: "9")]
        let withoutArchive = [mailbox(role: .inbox, id: "1")]

        #expect(SearchQueryCompiler.canSearch(query, mailboxes: withArchive))
        #expect(SearchQueryCompiler.canSearch(query, mailboxes: withoutArchive) == false)
    }

    @Test("a query naming no role can be served by every account")
    func noRole() {
        #expect(SearchQueryCompiler.canSearch(SearchQuery.parse("report"), mailboxes: []))
    }

    @Test("the role resolves to that account's own mailbox id")
    func resolvesRole() {
        let mailboxes = [mailbox(role: .inbox, id: "1"), mailbox(role: .archive, id: "9")]

        #expect(
            SearchQueryCompiler.mailboxID(
                for: SearchQuery.parse("in:archive"), mailboxes: mailboxes) == MailboxID("9")
        )
    }

    // MARK: - Feed identity

    /// Two different searches must not share rows, and returning to one should
    /// show its results rather than the other's.
    @Test("a search feed is keyed on the query")
    func feedIdentity() {
        #expect(FeedID.search("from:acme") == FeedID.search("  FROM:ACME  "))
        #expect(FeedID.search("from:acme") != FeedID.search("from:other"))
    }

    // MARK: - Helpers

    private func encoded(_ filter: EmailFilter) throws -> String {
        String(decoding: try JMAPRequest.encoder.encode(filter), as: UTF8.self)
    }

    private func mailbox(role: MailboxRole, id: String) -> MailboxSnapshot {
        MailboxSnapshot(
            accountKey: "server/1",
            mailboxID: MailboxID(id),
            labelID: nil,
            name: role.displayName,
            role: role,
            unreadThreads: 0,
            totalThreads: 0
        )
    }
}
