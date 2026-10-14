import Foundation
import JMAPKit
import Testing

@testable import PLMailCore

/// The operators added and corrected in Wave 2C, each pinned against what
/// `origin/main`'s `SearchQueryParser` and `EmailFilterCompiler` actually do.
///
/// The point of every assertion here is that a query means the same thing in
/// this app as it does in the browser. Where that means reproducing something
/// that looks like a bug, the test says so rather than quietly not covering it.
@Suite("Search operator parity")
struct SearchOperatorParityTests {
    // MARK: - cc:

    @Test("cc: is an operator, not three characters of free text")
    func ccParses() {
        let query = SearchQuery.parse("cc:carol invoice")

        #expect(query.cc == "carol")
        #expect(query.freeText == "invoice")
    }

    @Test("cc: compiles to the condition the server compiles")
    func ccCompiles() throws {
        let filter = try #require(
            SearchQueryCompiler.filter(for: SearchQuery.parse("cc:carol"), mailboxID: nil))

        #expect(try encoded(filter) == #"{"cc":"carol"}"#)
    }

    /// `bcc:` is a JMAP condition the server would answer and an operator the
    /// web UI does not have. Offering it would build a query that works on the
    /// phone and finds nothing in the browser.
    @Test("bcc: is not an operator, because the web UI has no such operator")
    func bccIsFreeText() {
        #expect(SearchQuery.parse("bcc:carol").freeText == "bcc:carol")
    }

    // MARK: - label:

    @Test("label: is parsed as a label name")
    func labelParses() {
        #expect(SearchQuery.parse("label:receipts").label == "receipts")
    }

    /// `LOWER(lbl.name) = :labelName` — exact and case-insensitive, so a
    /// prefix finds nothing and the wrong case finds everything it should.
    @Test("label: matches a leaf name exactly, ignoring case")
    func labelResolvesExactly() {
        let mailboxes = [
            mailbox(name: "Receipts", role: nil, id: "7"),
            mailbox(name: "Inbox", role: .inbox, id: "1"),
        ]

        #expect(
            SearchQueryCompiler.scope(
                for: SearchQuery.parse("label:RECEIPTS"), mailboxes: mailboxes
            ).mailboxIDs == [MailboxID("7")]
        )

        #expect(
            SearchQueryCompiler.scope(for: SearchQuery.parse("label:rec"), mailboxes: mailboxes)
                .gap == .label("rec")
        )
    }

    /// `AND lbl.role IS NULL`. `in:inbox` is the operator for a role mailbox,
    /// and the two are genuinely different questions.
    @Test("label: never matches a role mailbox")
    func labelExcludesRoles() {
        let mailboxes = [mailbox(name: "Inbox", role: .inbox, id: "1")]

        #expect(
            SearchQueryCompiler.scope(for: SearchQuery.parse("label:inbox"), mailboxes: mailboxes)
                .gap == .label("inbox")
        )
    }

    /// No leaf name can contain a slash — `MailboxSetMethod::requireName`
    /// refuses one — so a path matches nothing, and resolving it "helpfully"
    /// would answer a query the browser cannot.
    @Test("label: is not hierarchy-aware, so a path finds nothing")
    func labelIgnoresPaths() {
        let mailboxes = [mailbox(name: "Invoices", role: nil, id: "7")]

        #expect(
            SearchQueryCompiler.scope(
                for: SearchQuery.parse("label:work/invoices"), mailboxes: mailboxes
            ).canSearch == false
        )
    }

    /// A label is user-scoped, a Mailbox is a per-account binding: the same
    /// name is a different id in each account, and an account with no binding
    /// has to be skipped exactly as a missing role is skipped.
    @Test("label: resolves per account, and an account without it is skipped")
    func labelIsPerAccount() {
        let query = SearchQuery.parse("label:receipts")

        #expect(
            SearchQueryCompiler.scope(
                for: query, mailboxes: [mailbox(name: "Receipts", role: nil, id: "3")]
            ).mailboxIDs == [MailboxID("3")]
        )

        #expect(SearchQueryCompiler.canSearch(query, mailboxes: []) == false)
    }

    @Test("in: and label: together narrow by both, not by whichever came first")
    func labelAndRoleTogether() throws {
        let query = SearchQuery.parse("in:inbox label:receipts")
        let mailboxes = [
            mailbox(name: "Inbox", role: .inbox, id: "1"),
            mailbox(name: "Receipts", role: nil, id: "7"),
        ]

        let scope = SearchQueryCompiler.scope(for: query, mailboxes: mailboxes)
        let json = try encoded(#require(SearchQueryCompiler.filter(for: query, scope: scope)))

        #expect(json.contains(#"{"inMailbox":"1"}"#))
        #expect(json.contains(#"{"inMailbox":"7"}"#))
    }

    /// Nothing rather than an under-narrowed page of everything: the old
    /// single-id entry point cannot express a label binding, and a filter that
    /// quietly drops a narrowing looks exactly like a search that was ignored.
    @Test("the single-mailbox entry point refuses a query it cannot honour")
    func legacyEntryPointRefusesLabels() {
        #expect(
            SearchQueryCompiler.filter(for: SearchQuery.parse("label:receipts"), mailboxID: nil)
                == nil
        )
    }

    // MARK: - in:

    @Test("the server's spelling of a role is what reaches the mailbox lookup")
    func spamIsJunkHere() {
        let mailboxes = [mailbox(name: "Spam", role: .junk, id: "4")]

        #expect(
            SearchQueryCompiler.mailboxID(for: SearchQuery.parse("in:spam"), mailboxes: mailboxes)
                == MailboxID("4")
        )
        #expect(
            SearchQueryCompiler.mailboxID(for: SearchQuery.parse("in:junk"), mailboxes: mailboxes)
                == MailboxID("4")
        )
    }

    /// The stale server tree compiled this to "not in the Inbox". `origin/main`
    /// treats archive as an ordinary role, which is what this client already
    /// did — recorded so nobody reverses it back.
    @Test("in:archive means the Archive label, not the absence of Inbox")
    func archiveIsALabel() throws {
        let query = SearchQuery.parse("in:archive")
        let mailboxes = [mailbox(name: "Archive", role: .archive, id: "9")]
        let filter = try #require(
            SearchQueryCompiler.filter(
                for: query, scope: SearchQueryCompiler.scope(for: query, mailboxes: mailboxes)))

        #expect(try encoded(filter) == #"{"inMailbox":"9"}"#)
    }

    @Test("an account missing the named role says which role it was missing")
    func roleGapIsNamed() {
        #expect(
            SearchQueryCompiler.scope(for: SearchQuery.parse("in:archive"), mailboxes: []).gap
                == .role("archive")
        )
    }

    // MARK: - Free-text fallback

    /// PHP writes `(bool) ($filters->from = $value)`, and PHP reads the string
    /// "0" as false. So the filter is set *and* the token is searched for. Kept
    /// because the contract is that both clients answer a query the same way,
    /// not that both clients are sensible.
    @Test("a value of \"0\" is both a filter and free text, as it is server-side")
    func phpZeroQuirk() {
        let query = SearchQuery.parse("from:0")

        #expect(query.from == "0")
        #expect(query.freeText == "from:0")
    }

    @Test("a half-typed operator is neither a filter nor a word")
    func halfTypedOperator() {
        let query = SearchQuery.parse("label:")

        #expect(query.freeText.isEmpty)
        #expect(SearchQueryCompiler.filter(for: query, mailboxID: nil) == nil)
    }

    /// The counterpart: an unknown name with an empty value is a word somebody
    /// typed, and swallowing it left them searching for nothing at all.
    @Test("Re: stays searchable as the word somebody typed")
    func unknownOperatorKeepsItsColon() {
        #expect(SearchQuery.parse("Re:").freeText == "Re:")
    }

    // MARK: - Dates

    @Test(
        "the date spellings that survive tokenising are accepted",
        arguments: ["2024-1-5", "2024/1/5", "5.1.2024", "@1700000000", "tomorrow", "now"]
    )
    func widerDateGrammar(input: String) {
        #expect(SearchQuery.parseDate(input) != nil)
    }

    @Test("a date the parser cannot read is searched for as words")
    func unreadableDate() {
        let query = SearchQuery.parse("after:whenever")

        #expect(query.after == nil)
        #expect(query.freeText == "after:whenever")
    }

    // MARK: - Snippet batching

    /// The server refuses more than 500 ids outright and this client treats any
    /// snippet failure as "no highlighting", so one oversized request cost every
    /// row in every account its highlighting at once.
    @Test("snippet ids are split into requests the server will accept")
    func snippetBatching() {
        let ids = Array(1...1_201)
        let batches = SearchSnippetBatch.batches(ids)

        #expect(batches.count == 3)
        #expect(batches.allSatisfy { $0.count <= SearchSnippetBatch.maximumIDs })
        #expect(batches.flatMap { $0 } == ids, "order and membership both survive")
    }

    @Test("no ids means no request at all")
    func emptySnippetBatching() {
        #expect(SearchSnippetBatch.batches([Int]()).isEmpty)
    }

    // MARK: - threadCategory

    /// The plMail extension behind the Gmail-style tabs. Typed rather than a
    /// raw string because the server answers an unknown value with
    /// `invalidArguments`, which is a round trip spent learning something the
    /// client can know at compile time.
    @Test("threadCategory sends the token the server's enum spells")
    func threadCategoryEncoding() throws {
        #expect(
            try encoded(.threadCategory(.promotions)) == #"{"threadCategory":"promotions"}"#
        )
        #expect(
            MessageCategory.allCases.map(\.rawValue)
                == ["primary", "social", "promotions", "updates", "forums"]
        )
    }

    /// `category:` is not a `SearchQueryParser` operator, so putting one in this
    /// search box would create an operator the web does not have — the exact
    /// divergence the rest of this suite exists to prevent.
    @Test("category: is not a search operator, because the server has none")
    func categoryIsNotAnOperator() {
        #expect(SearchQuery.parse("category:promotions").freeText == "category:promotions")
    }

    // MARK: - Contradiction

    @Test("a query asking for read and unread mail knows that it is contradictory")
    func contradictionIsDetectable() {
        #expect(SearchQuery.parse("is:read is:unread").isContradictory)
        #expect(SearchQuery.parse("is:unread").isContradictory == false)
    }

    @Test("resolving the contradiction edits the visible text, keeping the rest")
    func contradictionResolves() {
        #expect(
            SearchQueryEditor.removingRead(in: "invoice is:read is:unread") == "invoice is:unread"
        )
    }

    // MARK: - Helpers

    private func encoded(_ filter: EmailFilter) throws -> String {
        String(decoding: try JMAPRequest.encoder.encode(filter), as: UTF8.self)
    }

    private func mailbox(name: String, role: MailboxRole?, id: String) -> MailboxSnapshot {
        MailboxSnapshot(
            accountKey: "server/1",
            mailboxID: MailboxID(id),
            labelID: nil,
            name: name,
            role: role,
            unreadThreads: 0,
            totalThreads: 0
        )
    }
}
