import Foundation
import Testing

@testable import PLMailCore

/// The chips edit the query *text*, which is the whole design: what ran and
/// what the field says can never disagree. These tests are therefore about
/// round-tripping — a chip turned on and off again must leave the rest of
/// somebody's query exactly as they wrote it.
@Suite("Search filter chips")
struct SearchQueryEditorTests {
    // MARK: - Toggling

    @Test("a chip writes its operator into the query", arguments: SearchFilterChip.allCases)
    func writesOperator(chip: SearchFilterChip) {
        let edited = SearchQueryEditor.toggling(chip, in: "invoice")
        let parsed = SearchQuery.parse(edited)

        #expect(edited.contains(chip.token))
        #expect(SearchQueryEditor.isActive(chip, in: parsed))
        // The typed part survives.
        #expect(parsed.freeText == "invoice")
    }

    @Test("toggling twice returns the original query", arguments: SearchFilterChip.allCases)
    func roundTrip(chip: SearchFilterChip) {
        let original = "invoice from:ada"
        let on = SearchQueryEditor.toggling(chip, in: original)

        #expect(SearchQueryEditor.toggling(chip, in: on) == original)
    }

    @Test("a chip composes with what was typed rather than replacing it")
    func composes() {
        var raw = "from:ada"
        raw = SearchQueryEditor.toggling(.unread, in: raw)
        raw = SearchQueryEditor.toggling(.hasAttachment, in: raw)

        let parsed = SearchQuery.parse(raw)

        #expect(parsed.from == "ada")
        #expect(parsed.isUnread == true)
        #expect(parsed.hasAttachment == true)
    }

    /// A chip that ignored typed text would be lying about the query that ran.
    @Test("a hand-typed operator lights the chip")
    func derivedFromText() {
        let parsed = SearchQuery.parse("is:unread has:attachments")

        #expect(SearchQueryEditor.isActive(.unread, in: parsed))
        #expect(SearchQueryEditor.isActive(.hasAttachment, in: parsed))
    }

    /// The parser accepts both spellings, so the chip has to clear the one it
    /// lit up for — otherwise tapping it off leaves the filter in place.
    @Test("the chip clears the plural spelling it lit up for")
    func pluralSpelling() {
        let edited = SearchQueryEditor.toggling(.hasAttachment, in: "has:attachments invoice")

        #expect(SearchQuery.parse(edited).hasAttachment == nil)
        #expect(SearchQuery.parse(edited).freeText == "invoice")
    }

    /// Both flags set returns nothing on either client, so a chip leaving that
    /// behind would simply look broken. The conflicting operator is removed
    /// from visible text, not overridden behind it.
    @Test("turning unread on clears a contradicting is:read")
    func clearsContradiction() {
        let edited = SearchQueryEditor.toggling(.unread, in: "is:read invoice")
        let parsed = SearchQuery.parse(edited)

        #expect(parsed.isUnread == true)
        #expect(parsed.isRead == nil)
    }

    /// A quoted phrase must survive token surgery intact, or narrowing by a
    /// chip would quietly turn a phrase search into a bag of words.
    @Test("a quoted phrase survives a chip")
    func quotedPhraseSurvives() {
        let edited = SearchQueryEditor.toggling(.unread, in: "subject:\"quarterly report\"")

        #expect(SearchQuery.parse(edited).subject == "quarterly report")
        #expect(SearchQuery.parse(edited).isUnread == true)
    }

    // MARK: - Dates

    @Test("a date preset writes a parseable after:")
    func datePreset() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let date = try #require(SearchDatePreset.month.date(from: now))
        let edited = SearchQueryEditor.settingAfter(date, in: "invoice")

        let parsed = SearchQuery.parse(edited)
        let after = try #require(parsed.after)

        #expect(Calendar.current.isDate(after, inSameDayAs: date))
        #expect(parsed.freeText == "invoice")
    }

    /// Picking a second range must replace the first, not AND two bounds
    /// together — `after:` twice would leave the later one winning silently.
    @Test("a second date preset replaces the first")
    func dateReplaces() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let week = try #require(SearchDatePreset.week.date(from: now))
        let year = try #require(SearchDatePreset.year.date(from: now))

        let once = SearchQueryEditor.settingAfter(week, in: "invoice")
        let twice = SearchQueryEditor.settingAfter(year, in: once)

        #expect(twice.components(separatedBy: "after:").count == 2)

        let bound = try #require(SearchQuery.parse(twice).after)

        #expect(Calendar.current.isDate(bound, inSameDayAs: year))
    }

    @Test("clearing the date removes the operator")
    func dateCleared() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let date = try #require(SearchDatePreset.week.date(from: now))
        let set = SearchQueryEditor.settingAfter(date, in: "invoice")

        #expect(SearchQueryEditor.settingAfter(nil, in: set) == "invoice")
    }

    @Test("the active preset is recognised from the query", arguments: SearchDatePreset.allCases)
    func activePreset(preset: SearchDatePreset) throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let date = try #require(preset.date(from: now))
        let raw = SearchQueryEditor.settingAfter(date, in: "")

        #expect(SearchQueryEditor.activePreset(in: SearchQuery.parse(raw), now: now) == preset)
    }

    @Test("a query with no date has no active preset")
    func noActivePreset() {
        #expect(SearchQueryEditor.activePreset(in: SearchQuery.parse("invoice")) == nil)
    }

    /// Resolved against a calendar rather than by subtracting intervals, so the
    /// presets are genuinely different lengths and land on day boundaries.
    @Test("the presets go back in the right order")
    func presetOrder() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let week = try #require(SearchDatePreset.week.date(from: now))
        let month = try #require(SearchDatePreset.month.date(from: now))
        let year = try #require(SearchDatePreset.year.date(from: now))

        #expect(year < month)
        #expect(month < week)
        #expect(week < now)
    }
}
