import Testing

@testable import PLMailUI

/// The chips are a view of the recipient string, so every one of these is
/// really a question about that string: after drawing a chip, removing one, or
/// typing past a comma, does the field still name exactly the people it named?
///
/// A composer that loses a recipient loses it silently — the message goes to
/// fewer people than the sender saw listed, and nothing reports it. That is the
/// failure this suite exists for.
@Suite("Recipient tokens")
struct RecipientTokensTests {

    @Test("nothing is committed until a separator says so")
    func typingIsNotYetARecipient() {
        #expect(RecipientTokens.committed(in: "anna@example.org") == [])
        #expect(RecipientTokens.fragment(in: "anna@example.org") == "anna@example.org")
    }

    @Test("a separator commits the recipient before it and clears the field")
    func separatorCommits() {
        #expect(RecipientTokens.committed(in: "anna@example.org, ") == ["anna@example.org"])
        #expect(RecipientTokens.fragment(in: "anna@example.org, ") == "")
    }

    /// The reason the split is `RecipientParsing`'s and not `split(separator:)`:
    /// an Outlook address carries a comma inside its quoted display name, and
    /// cutting there produces two chips, neither of them a person.
    @Test("a comma inside a quoted display name is not a separator")
    func quotedNameStaysOneRecipient() {
        let field = "\"Meyer, Anna\" <anna@example.org>, "

        #expect(RecipientTokens.committed(in: field) == ["\"Meyer, Anna\" <anna@example.org>"])
        #expect(RecipientTokens.fragment(in: field) == "")
    }

    @Test("removing a chip leaves every other recipient, and what is being typed")
    func removalKeepsTheRest() {
        let field = "a@example.org, b@example.org, c@ex"
        let after = RecipientTokens.removing(at: 0, in: field)

        #expect(after == "b@example.org, c@ex")
        #expect(RecipientTokens.committed(in: after) == ["b@example.org"])
        #expect(RecipientTokens.fragment(in: after) == "c@ex")
    }

    /// Two chips can be the same address — a list pasted over one already
    /// there — and the one that was tapped is the one that has to go.
    @Test("removal is by position, so a repeated address loses the right copy")
    func removalIsPositional() {
        let field = "a@example.org, b@example.org, a@example.org, "

        #expect(
            RecipientTokens.removing(at: 2, in: field)
                == "a@example.org, b@example.org, ")
    }

    @Test("removing the last recipient leaves the fragment alone rather than the whole field")
    func removingTheOnlyChip() {
        #expect(RecipientTokens.removing(at: 0, in: "a@example.org, half") == "half")
        #expect(RecipientTokens.removing(at: 0, in: "a@example.org, ").isEmpty)
    }

    /// Guarded rather than trapping: a chip and the string it was drawn from
    /// can disagree for one frame while a keystroke lands.
    @Test("a removal past the end changes nothing")
    func removalOutOfRange() {
        #expect(RecipientTokens.removing(at: 4, in: "a@example.org, ") == "a@example.org, ")
    }

    @Test("committing a recipient always leaves the field ready for the next one")
    func joinedKeepsRecipientsSettled() {
        let field = RecipientTokens.joined(["a@example.org"], typing: "")

        #expect(field == "a@example.org, ")
        // The round trip is the invariant: what was settled stays settled.
        #expect(RecipientTokens.committed(in: field) == ["a@example.org"])
    }

    @Test("an empty field has no recipients and nothing being typed")
    func emptyField() {
        #expect(RecipientTokens.committed(in: "") == [])
        #expect(RecipientTokens.fragment(in: "").isEmpty)
        #expect(RecipientTokens.endsWithSeparator("") == false)
    }
}
