import Foundation
import JMAPKit
import Testing

@testable import PLMailCore

/// Recent searches are the one part of search that is not reconstructible, so
/// the behaviour worth pinning is the bookkeeping: order, deduplication, and
/// the cap.
@Suite("Recent searches")
struct RecentSearchTests {
    /// Its own suite per test, so one test's history cannot leak into another's
    /// and neither touches the machine's real defaults.
    private static func isolated() -> RecentSearches {
        let name = "de.plmail.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!

        defaults.removePersistentDomain(forName: name)

        return RecentSearches(defaults: defaults)
    }

    @Test("the most recent search comes first")
    func ordering() {
        let recents = Self.isolated()

        recents.record("from:ada")
        recents.record("invoice")

        #expect(recents.all() == ["invoice", "from:ada"])
    }

    /// Re-running a search should move it, not append a second copy — otherwise
    /// a query someone uses daily fills the whole list.
    @Test("repeating a search moves it rather than duplicating it")
    func deduplication() {
        let recents = Self.isolated()

        recents.record("from:ada")
        recents.record("invoice")
        recents.record("from:ada")

        #expect(recents.all() == ["from:ada", "invoice"])
    }

    /// The parser case-folds operator names, so these are the same search and
    /// offering both would be a choice that isn't one.
    @Test("case does not make a different search")
    func caseInsensitiveDeduplication() {
        let recents = Self.isolated()

        recents.record("from:ada")
        recents.record("From:Ada")

        #expect(recents.all() == ["From:Ada"])
    }

    @Test("blank searches are not recorded")
    func blanks() {
        let recents = Self.isolated()

        recents.record("")
        recents.record("   ")

        #expect(recents.all().isEmpty)
    }

    @Test("the list is capped")
    func cap() {
        let recents = Self.isolated()

        for index in 0..<(RecentSearches.limit + 5) { recents.record("query \(index)") }

        #expect(recents.all().count == RecentSearches.limit)
        // The cap must drop the oldest, not refuse the newest.
        #expect(recents.all().first == "query \(RecentSearches.limit + 4)")
    }

    @Test("one entry can be forgotten")
    func forget() {
        let recents = Self.isolated()

        recents.record("from:ada")
        recents.record("invoice")
        recents.forget("from:ada")

        #expect(recents.all() == ["invoice"])
    }
}

/// A completion replaces the token being typed and nothing else. Getting this
/// wrong throws away what somebody has already written, which is the worst a
/// suggestion list can do.
@Suite("Search draft splitting")
struct SearchDraftTests {
    @Test("a single word is the whole active token")
    func singleToken() {
        let draft = SearchDraft.of("from")

        #expect(draft.prefix.isEmpty)
        #expect(draft.activeToken == "from")
    }

    @Test("earlier tokens are kept in the prefix")
    func prefixKept() {
        let draft = SearchDraft.of("from:ada has:att")

        #expect(draft.prefix == "from:ada ")
        #expect(draft.activeToken == "has:att")
        #expect(draft.completed(with: "has:attachment") == "from:ada has:attachment")
    }

    /// Three tokens, so splitting at the *first* space rather than the last is
    /// distinguishable — with only one space the two are the same answer, which
    /// is exactly how a wrong split hides.
    @Test("the split is at the last space, not the first")
    func lastSpaceWins() {
        let draft = SearchDraft.of("invoice from:ada has:att")

        #expect(draft.prefix == "invoice from:ada ")
        #expect(draft.activeToken == "has:att")
        #expect(
            draft.completed(with: "has:attachment") == "invoice from:ada has:attachment")
    }

    /// A trailing space means the next token is new and empty — completing here
    /// must append rather than overwrite the word just finished.
    @Test("a trailing space starts a new token")
    func trailingSpace() {
        let draft = SearchDraft.of("invoice ")

        #expect(draft.prefix == "invoice ")
        #expect(draft.activeToken.isEmpty)
        #expect(draft.completed(with: "is:unread") == "invoice is:unread")
    }

    /// The tokeniser's rule, so a half-typed phrase is not split mid-quote.
    @Test("a space inside quotes does not end the token")
    func quotedSpace() {
        let draft = SearchDraft.of("subject:\"quarterly rep")

        #expect(draft.prefix.isEmpty)
        #expect(draft.activeToken == "subject:\"quarterly rep")
    }
}

@Suite("Search suggestions")
struct SearchSuggestionTests {
    private static let correspondents = [
        EmailAddress(name: "Ada Lovelace", email: "ada@example.com"),
        EmailAddress(name: "Grace Hopper", email: "grace@example.com"),
    ]

    private static func suggest(
        _ raw: String, recents: [String] = [], limit: Int = 8
    ) -> [SearchSuggestion] {
        SearchSuggestions.suggest(
            for: raw, recents: recents, correspondents: correspondents, limit: limit)
    }

    /// The field has just been tapped. Past searches are the only thing that
    /// can be relevant; a wall of operator syntax as a greeting is not.
    @Test("an empty field offers recent searches only")
    func emptyOffersRecents() {
        let suggestions = Self.suggest("", recents: ["invoice", "from:ada"])

        #expect(suggestions.map(\.title) == ["invoice", "from:ada"])
        #expect(suggestions.allSatisfy { $0.kind == .recent })
    }

    @Test("operators are offered for a matching fragment")
    func operatorPrefix() {
        let titles = Self.suggest("fr").map(\.title)

        #expect(titles.contains("from:"))
    }

    /// People type the word they mean, not the namespace it lives under.
    @Test("an operator matches on the word after its colon")
    func operatorValueMatch() {
        #expect(Self.suggest("unr").map(\.title).contains("is:unread"))
        #expect(Self.suggest("att").map(\.title).contains("has:attachment"))
    }

    /// Completing to `from:` and searching immediately would search for
    /// nothing, so the caret has to stay put.
    @Test("an operator taking a value is not complete")
    func incompleteOperator() throws {
        let suggestion = try #require(Self.suggest("fr").first { $0.title == "from:" })

        #expect(suggestion.isComplete == false)

        let flag = try #require(Self.suggest("unr").first { $0.title == "is:unread" })

        #expect(flag.isComplete)
    }

    /// Once the operator is settled, what is wanted is a person.
    @Test("a settled operator suppresses further operator rows")
    func noOperatorsAfterColon() {
        let suggestions = Self.suggest("from:ad")

        #expect(suggestions.contains { $0.kind == .searchOperator } == false)
        #expect(suggestions.contains { $0.kind == .sender })
    }

    /// `from:` is a value-taking operator whose value has not been typed, so
    /// offering `from:` back would be a row that completes to the same string.
    @Test("a bare value-taking operator offers no operator rows")
    func bareValueOperator() {
        #expect(Self.suggest("from:").contains { $0.kind == .searchOperator } == false)
    }

    /// The exception to the rule above: `is:` and `has:` carry their value in
    /// the operator itself, so a half-typed one must still complete — and there
    /// is no address to offer instead.
    @Test(
        "a half-typed flag operator still completes",
        arguments: [
            ("is:u", "is:unread"), ("is:st", "is:starred"), ("has:att", "has:attachment"),
        ])
    func flagOperatorCompletes(input: String, expected: String) {
        let titles = Self.suggest(input).filter { $0.kind == .searchOperator }.map(\.title)

        #expect(titles.contains(expected), "\(input) should still offer \(expected)")
    }

    /// A suggestion completing to exactly what is in the field does nothing but
    /// take up a row.
    @Test("a fully typed operator is not offered back")
    func noEchoRow() {
        #expect(Self.suggest("is:unread").contains { $0.kind == .searchOperator } == false)
    }

    @Test("a sender completes into the operator that was being typed")
    func senderCompletion() throws {
        let suggestion = try #require(Self.suggest("to:ada").first { $0.kind == .sender })

        #expect(suggestion.completion == "to:ada@example.com")
    }

    /// The teaching move: a bare fragment becomes a `from:` filter, which is
    /// what shows somebody the operator exists.
    @Test("a bare fragment offers senders as a from: filter")
    func bareFragmentTeachesFrom() throws {
        let suggestion = try #require(Self.suggest("ada").first { $0.kind == .sender })

        #expect(suggestion.completion == "from:ada@example.com")
    }

    @Test("a completion keeps everything already typed")
    func completionKeepsPrefix() throws {
        let suggestion = try #require(
            Self.suggest("invoice from:ad").first { $0.kind == .sender })

        #expect(suggestion.completion == "invoice from:ada@example.com")
    }

    /// `subject:` wants words, not an address book.
    @Test("operators that do not name a person get no sender rows")
    func noSendersForSubject() {
        #expect(Self.suggest("subject:ada").contains { $0.kind == .sender } == false)
    }

    @Test("a recent search matching what was typed is offered")
    func matchingRecent() {
        let suggestions = Self.suggest("inv", recents: ["invoice overdue", "from:grace"])

        #expect(suggestions.first?.title == "invoice overdue")
        #expect(suggestions.contains { $0.title == "from:grace" } == false)
    }

    /// A row that puts back the string already in the field does nothing.
    @Test("a recent search identical to the query is not offered")
    func exactRecentDropped() {
        let suggestions = Self.suggest("invoice", recents: ["invoice"])

        #expect(suggestions.contains { $0.kind == .recent } == false)
    }

    /// Without per-group caps a long history buries the operators, which are
    /// the one thing this list exists to teach.
    @Test("history cannot crowd out the operators")
    func groupCaps() {
        let recents = (0..<10).map { "from something \($0)" }
        let suggestions = Self.suggest("fr", recents: recents)

        #expect(suggestions.filter { $0.kind == .recent }.count <= 3)
        #expect(suggestions.contains { $0.kind == .searchOperator })
    }

    @Test("the overall limit is honoured")
    func limit() {
        #expect(Self.suggest("a", recents: ["a1", "a2", "a3"], limit: 4).count <= 4)
    }
}
