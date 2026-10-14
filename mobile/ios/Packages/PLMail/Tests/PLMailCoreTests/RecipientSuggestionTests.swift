import Foundation
import JMAPKit
import Testing

@testable import PLMailCore

/// Ranking the two suggestion sources against each other.
///
/// The address book cannot be tested — that needs a device and somebody
/// tapping Allow — so the merge is a pure function and this is where the
/// judgement lives.
@Suite("Recipient suggestions")
struct RecipientSuggestionTests {
    private func address(_ name: String?, _ email: String) -> EmailAddress {
        EmailAddress(name: name, email: email)
    }

    /// Somebody you have written to is a better guess than somebody whose card
    /// you happen to hold, and on a phone only the first two or three
    /// suggestions are ever seen.
    @Test("Correspondents outrank the address book")
    func correspondentsFirst() {
        let merged = RecipientSuggestions.merge(
            correspondents: [address("Ada Colleague", "ada@work.test")],
            contacts: [address("Ada Contact", "ada@book.test")],
            matching: "ada")

        #expect(merged.map(\.email) == ["ada@work.test", "ada@book.test"])
    }

    /// The same person is usually in both lists.
    @Test("A person in both lists appears once")
    func deduplicates() {
        let merged = RecipientSuggestions.merge(
            correspondents: [address("Ada", "ada@example.test")],
            contacts: [address("Ada Lovelace", "ADA@example.test")],
            matching: "ada")

        #expect(merged.count == 1)
        // The correspondent won, so the name is the one from mail.
        #expect(merged.first?.name == "Ada")
    }

    /// Typing a surname is ordinary, and the person should not be buried under
    /// every address that merely contains those letters.
    @Test("A surname counts as a prefix match")
    func surnameRanksAsPrefix() {
        let merged = RecipientSuggestions.merge(
            correspondents: [
                address(nil, "team@lovegrove.test"),
                address("Ada Lovelace", "ada@example.test"),
            ],
            matching: "love")

        #expect(merged.first?.email == "ada@example.test")
    }

    @Test("An email prefix outranks a substring")
    func emailPrefixFirst() {
        let merged = RecipientSuggestions.merge(
            correspondents: [
                address(nil, "no-reply@adacorp.test"),
                address(nil, "ada@example.test"),
            ],
            matching: "ada")

        #expect(merged.map(\.email) == ["ada@example.test", "no-reply@adacorp.test"])
    }

    /// One letter matches most of an address book. Suggesting on it is noise,
    /// and in the contacts case it would mean a permission prompt for a list
    /// nobody can use.
    @Test("A single character suggests nothing", arguments: ["", "a", " a "])
    func tooShort(fragment: String) {
        let merged = RecipientSuggestions.merge(
            correspondents: [address("Ada", "ada@example.test")], matching: fragment)

        #expect(merged.isEmpty)
    }

    @Test("The list is capped")
    func capped() {
        let many = (0..<20).map { address("Person \($0)", "ada\($0)@example.test") }

        #expect(RecipientSuggestions.merge(correspondents: many, matching: "ada").count == 5)
    }

    /// Blank addresses turn up in real data — see the identity with no email on
    /// my own test server — and a suggestion you cannot pick is worse than no
    /// suggestion.
    ///
    /// The names have to match the fragment, or this passes for the wrong
    /// reason: an address that fails the match anyway never reaches the guard,
    /// which is exactly how the first version of this test was green while the
    /// guard did nothing. Two of them, because the guard's real job is the
    /// dedupe — without it both collide on the empty key and one survives.
    @Test("Addresses with no email are dropped")
    func skipsBlankAddresses() {
        let merged = RecipientSuggestions.merge(
            correspondents: [address("Ada Nobody", ""), address("Ada Someone", "")],
            matching: "ada")

        #expect(merged.isEmpty)
    }

    @Test("A blank address does not crowd out a real one")
    func blankDoesNotDisplace() {
        let merged = RecipientSuggestions.merge(
            correspondents: [address("Ada Nobody", ""), address("Ada", "ada@example.test")],
            matching: "ada")

        #expect(merged.map(\.email) == ["ada@example.test"])
    }

    @Test("Matching ignores case on both sides")
    func caseInsensitive() {
        let merged = RecipientSuggestions.merge(
            correspondents: [address("ADA LOVELACE", "Ada@Example.test")], matching: "aDa")

        #expect(merged.count == 1)
    }
}

extension RecipientSuggestions {
    /// Convenience for the many cases that only exercise one source.
    fileprivate static func merge(
        correspondents: [EmailAddress], matching fragment: String
    ) -> [EmailAddress] {
        merge(correspondents: correspondents, contacts: [], matching: fragment)
    }
}
