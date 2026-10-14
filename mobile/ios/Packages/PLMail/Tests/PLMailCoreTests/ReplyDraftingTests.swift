import Foundation
import JMAPKit
import Testing

@testable import PLMailCore

/// What a reply or a forward starts as. Every rule here was wrong in a way
/// only the recipient could see.
@Suite("Reply drafting")
struct ReplyDraftingTests {
    // MARK: - Subjects

    @Test(
        "Prefixes are stripped rather than stacked, across both languages",
        arguments: [
            ("Angebot", "Angebot"),
            ("Re: Angebot", "Angebot"),
            ("AW: Angebot", "Angebot"),
            ("WG: Angebot", "Angebot"),
            ("Fwd: Angebot", "Angebot"),
            ("Re[2]: Angebot", "Angebot"),
            ("RE[10]: Angebot", "Angebot"),
            ("AW: WG: Re: Angebot", "Angebot"),
            ("Re: Fwd: Angebot", "Angebot"),
            ("antw: Angebot", "Angebot"),
            ("SV: Angebot", "Angebot"),
        ])
    func stripping(_ subject: String, _ expected: String) {
        #expect(ReplyDrafting.strippingPrefixes(subject) == expected)
    }

    /// A word that merely ends in a colon is not a prefix. Losing the first
    /// word of a real subject is the failure on the other side of this rule.
    @Test(
        "A subject that only looks like a prefix is left alone",
        arguments: ["Report: Q3", "Status: green", "Rechnung 4: bezahlt"])
    func notAPrefix(_ subject: String) {
        #expect(ReplyDrafting.strippingPrefixes(subject) == subject)
    }

    @Test("A reply to a forward is Re:, not Re: Fwd:")
    func replyToForward() {
        #expect(ReplyDrafting.replySubject("Fwd: Angebot") == "Re: Angebot")
        #expect(ReplyDrafting.replySubject("AW: Angebot") == "Re: Angebot")
        #expect(ReplyDrafting.forwardSubject("Re: Angebot") == "Fwd: Angebot")
    }

    @Test("A missing subject still gets a prefix")
    func missingSubject() {
        #expect(ReplyDrafting.replySubject(nil) == "Re: ")
    }

    // MARK: - References

    @Test("References keeps the root and the most recent nineteen")
    func referencesCap() {
        let existing = (1...50).map { "m\($0)@x.test" }
        let capped = ReplyDrafting.references(continuing: existing, with: "new@x.test")

        #expect(capped.count == ReplyDrafting.referencesLimit)
        // The root is what every threading algorithm finds the conversation by.
        #expect(capped.first == "m1@x.test")
        #expect(capped.last == "new@x.test")
        #expect(capped.contains("m2@x.test") == false)
    }

    @Test("A short thread is left whole")
    func referencesUncapped() {
        #expect(
            ReplyDrafting.references(continuing: ["a@x.test"], with: "b@x.test")
                == ["a@x.test", "b@x.test"])
    }

    /// A draft has no Message-ID — plMail assigns one at send — so replying to
    /// one must not fabricate an id to thread with.
    @Test("Without a Message-ID nothing is added")
    func referencesWithoutMessageID() {
        #expect(ReplyDrafting.references(continuing: ["a@x.test"], with: nil) == ["a@x.test"])
    }

    // MARK: - Recipients

    private let ada = EmailAddress(name: "Ada", email: "ada@example.org")
    private let bob = EmailAddress(name: "Bob", email: "bob@example.org")
    private let me = EmailAddress(name: "Me", email: "me@example.org")
    private let alias = EmailAddress(name: "Work", email: "work@example.org")

    @Test("Reply-all never Ccs any address the user can send as")
    func replyAllExcludesOwnIdentities() {
        let result = ReplyDrafting.replyRecipients(
            answering: [ada],
            originalTo: [me, bob],
            originalCc: [alias],
            all: true,
            own: ["me@example.org", "work@example.org"]
        )

        #expect(result.to == [ada])
        #expect(result.cc == [bob])
    }

    @Test("Reply-all keeps header order rather than sorting alphabetically")
    func replyAllKeepsOrder() {
        let zoe = EmailAddress(name: "Zoe", email: "zoe@example.org")
        let result = ReplyDrafting.replyRecipients(
            answering: [ada], originalTo: [zoe, bob], originalCc: [], all: true, own: [])

        #expect(result.cc.map(\.email) == ["zoe@example.org", "bob@example.org"])
    }

    @Test("Nobody appears in both To and Cc")
    func replyAllDeduplicatesAgainstTo() {
        let result = ReplyDrafting.replyRecipients(
            answering: [ada], originalTo: [ada, bob], originalCc: [bob], all: true, own: [])

        #expect(result.to == [ada])
        #expect(result.cc == [bob])
    }

    @Test("A plain reply carries no Cc at all")
    func plainReply() {
        let result = ReplyDrafting.replyRecipients(
            answering: [ada], originalTo: [bob], originalCc: [me], all: false, own: [])

        #expect(result.cc.isEmpty)
    }

    // MARK: - Forwarding

    @Test("The forward header block names the original and escapes it")
    func forwardBlock() {
        let block = ReplyDrafting.forwardBlock(
            from: "Ada <ada@example.org>",
            date: Date(timeIntervalSince1970: 0),
            subject: "A <b> subject",
            to: [bob],
            cc: []
        )

        #expect(block.contains("Forwarded message"))
        #expect(block.contains("&lt;b&gt;"))
        // Reusing the reply quote produced "wrote:" above a message nobody
        // wrote to the forwarder.
        #expect(block.contains("wrote") == false)
        #expect(block.contains("Cc") == false)
    }
}
