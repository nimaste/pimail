import Foundation
import JMAPKit
import JMAPTestSupport
import Testing

@testable import PLMailCore

/// `mailto:` links, which arrive from outside the app and are therefore
/// hostile until parsed.
///
/// The parser is pure logic with no store, no server and no main actor behind
/// it, which is exactly why it is tested this hard: everything it gets wrong is
/// silent. A recipient dropped, a recipient invented, a subject that becomes a
/// second header, a body that becomes markup — none of those announce
/// themselves, and all of them reach somebody else's inbox.
@Suite("mailto: links")
struct MailtoTests {

    // MARK: - Shape

    @Test("a link with nothing after the scheme is a blank message, not a failure")
    func bareSchemeParses() throws {
        let request = try #require(Mailto.parse("mailto:"))

        #expect(request.isEmpty)
        #expect(request.to.isEmpty)
    }

    @Test("anything that is not a mailto: is refused so the pairing link still works")
    func otherSchemesAreRefused() {
        #expect(Mailto.parse("plmail://pair?code=abc") == nil)
        #expect(Mailto.parse("https://example.org/mailto:a@b.example") == nil)
        #expect(Mailto.parse("") == nil)
        #expect(Mailto.parse(nil) == nil)
        #expect(Mailto.parse("mail-to:a@b.example") == nil)
    }

    /// Links in the wild are written by hand and `MAILTO:` appears in real
    /// HTML. Refusing it would mean the app opened and did nothing.
    @Test("the scheme matches whatever case the link was written in")
    func schemeIsCaseInsensitive() throws {
        #expect(try #require(Mailto.parse("MAILTO:a@b.example")).to == ["a@b.example"])
        #expect(try #require(Mailto.parse("MailTo:a@b.example")).to == ["a@b.example"])
    }

    @Test("a URL is read from its own text rather than from re-parsed components")
    func parsesFromURL() throws {
        let url = try #require(URL(string: "mailto:a@b.example?subject=Hi&body=There"))
        let request = try #require(Mailto.parse(url))

        #expect(request.to == ["a@b.example"])
        #expect(request.subject == "Hi")
        #expect(request.body == "There")
    }

    // MARK: - Recipients

    @Test("every recipient in the path is kept, in order")
    func multipleRecipients() throws {
        let request = try #require(Mailto.parse("mailto:a@x.example,b@y.example,c@z.example"))

        #expect(request.to == ["a@x.example", "b@y.example", "c@z.example"])
    }

    /// RFC 6068 allows both spellings and one link may carry both, so the two
    /// lists are one list. Replacing rather than appending would lose whichever
    /// half the link put first.
    @Test("addresses before the ? and a to= field concatenate rather than replace")
    func pathAndFieldConcatenate() throws {
        let request = try #require(Mailto.parse("mailto:a@x.example?to=b@y.example&to=c@z.example"))

        #expect(request.to == ["a@x.example", "b@y.example", "c@z.example"])
    }

    @Test("cc and bcc are read, and only from their own fields")
    func ccAndBcc() throws {
        let request = try #require(
            Mailto.parse("mailto:a@x.example?cc=b@y.example&bcc=c@z.example"))

        #expect(request.to == ["a@x.example"])
        #expect(request.cc == ["b@y.example"])
        #expect(request.bcc == ["c@z.example"])
        #expect(request.needsMoreRecipients)
    }

    @Test("a link with no cc or bcc leaves the composer's disclosure closed")
    func noHiddenRecipients() throws {
        #expect(try #require(Mailto.parse("mailto:a@x.example")).needsMoreRecipients == false)
    }

    @Test("empty entries in a recipient list are dropped rather than kept as blanks")
    func emptyEntriesDropped() throws {
        let request = try #require(Mailto.parse("mailto:a@x.example,,%20,b@y.example"))

        #expect(request.to == ["a@x.example", "b@y.example"])
    }

    /// The whole reason splitting and decoding are two steps. Decoding first
    /// cuts `"Meyer, Anna" <anna@example.org>` into two halves, neither of
    /// which is an address.
    @Test("an encoded comma inside a quoted display name does not split a recipient")
    func encodedCommaStaysInsideTheName() throws {
        let request = try #require(
            Mailto.parse("mailto:%22Meyer%2C%20Anna%22%20%3Canna@example.org%3E"))

        #expect(request.to == ["\"Meyer, Anna\" <anna@example.org>"])
        #expect(MailtoRequest.field(from: request.to) == "\"Meyer, Anna\" <anna@example.org>")
    }

    /// The decisive local case: `anna+lists@example.org` is how a good part of
    /// this audience filters their own mail, and form-decoding turns it into an
    /// address with a space in it that ``RecipientParsing`` then refuses.
    @Test("a plus sign in an address is a plus sign, never a space")
    func plusIsNotASpace() throws {
        let request = try #require(Mailto.parse("mailto:anna+lists@example.org"))

        #expect(request.to == ["anna+lists@example.org"])
        #expect(RecipientParsing.parse(request.to[0])?.email == "anna+lists@example.org")
    }

    @Test("a plus sign in a subject is also left alone")
    func plusSurvivesInSubject() throws {
        #expect(try #require(Mailto.parse("mailto:a@x.example?subject=2+2")).subject == "2+2")
    }

    // MARK: - Headers

    @Test("header names match whatever case the link used")
    func headerNamesAreCaseInsensitive() throws {
        let request = try #require(
            Mailto.parse("mailto:?TO=a@x.example&Subject=Hi&BODY=There&Cc=c@z.example"))

        #expect(request.to == ["a@x.example"])
        #expect(request.subject == "Hi")
        #expect(request.body == "There")
        #expect(request.cc == ["c@z.example"])
    }

    /// The reason every other client ignores them: a link that can set the
    /// sender composes mail in somebody else's name from a page the user merely
    /// visited.
    @Test("from, reply-to and any other header are read past rather than honoured")
    func onlyFiveHeadersAreHonoured() throws {
        let request = try #require(
            Mailto.parse(
                "mailto:a@x.example?from=ceo@bank.example&reply-to=thief@x.example"
                    + "&in-reply-to=%3Cabc%40x%3E&x-priority=1&sender=nobody@x.example"))

        #expect(request.to == ["a@x.example"])
        #expect(request.cc.isEmpty)
        #expect(request.bcc.isEmpty)
        #expect(request.subject.isEmpty)
        #expect(request.body.isEmpty)
        #expect(Mailto.honouredHeaders == ["to", "cc", "bcc", "subject", "body"])
    }

    @Test("a field with no value, and an empty field, are both survivable")
    func malformedFieldsSurvive() throws {
        let request = try #require(Mailto.parse("mailto:a@x.example?subject&&=&body="))

        #expect(request.to == ["a@x.example"])
        #expect(request.subject.isEmpty)
        #expect(request.body.isEmpty)
    }

    @Test("an ampersand inside a subject survives when it was encoded")
    func encodedAmpersandStaysInTheSubject() throws {
        let request = try #require(Mailto.parse("mailto:a@x.example?subject=Bell%26Ross"))

        #expect(request.subject == "Bell&Ross")
    }

    // MARK: - Percent decoding

    /// `%C3%A4` is one `ä`. Decoding each escape on its own yields two
    /// replacement marks, and every German subject line comes through here.
    @Test("a run of escapes decodes as bytes rather than one character each")
    func multiByteEscapes() throws {
        let request = try #require(
            Mailto.parse("mailto:a@x.example?subject=Gr%C3%BC%C3%9Fe&body=%F0%9F%93%AC"))

        #expect(request.subject == "Grüße")
        #expect(request.body == "📬")
    }

    @Test("escapes split by literal text still decode correctly on both sides")
    func escapesAroundLiterals() throws {
        let request = try #require(Mailto.parse("mailto:a@x.example?subject=%C3%A4b%C3%B6"))

        #expect(request.subject == "äbö")
    }

    /// A hand-written link with a per cent sign in the subject is far likelier
    /// than a truncated escape, and failing would turn a defect in somebody
    /// else's HTML into a composer that refuses to open.
    @Test("a % that is not an escape stays a %")
    func brokenEscapesStayLiteral() throws {
        #expect(try #require(Mailto.parse("mailto:a@x.example?subject=100%")).subject == "100%")
        #expect(try #require(Mailto.parse("mailto:a@x.example?subject=50%25")).subject == "50%")
        #expect(try #require(Mailto.parse("mailto:a@x.example?subject=%zz")).subject == "%zz")
        #expect(try #require(Mailto.parse("mailto:a@x.example?subject=%2")).subject == "%2")
        #expect(try #require(Mailto.parse("mailto:a@x.example?subject=a%")).subject == "a%")
    }

    @Test("malformed UTF-8 becomes a replacement mark rather than an error")
    func malformedUTF8Survives() throws {
        let request = try #require(Mailto.parse("mailto:a@x.example?subject=%FF%FE"))

        #expect(request.subject.isEmpty == false)
        #expect(request.to == ["a@x.example"])
    }

    @Test("an escaped @ in a recipient still reads as an address")
    func escapedAtSign() throws {
        let request = try #require(Mailto.parse("mailto:a%40x.example"))

        #expect(request.to == ["a@x.example"])
    }

    // MARK: - Hostile input

    /// The header-injection case. This client sends over JMAP, where a subject
    /// is a JSON string — but the same string is written to a draft the server
    /// later renders into RFC 5322, and a newline that reaches a header field
    /// there is a header somebody else wrote.
    @Test("a CRLF in a subject cannot become a second header")
    func crlfInSubjectIsFlattened() throws {
        let request = try #require(
            Mailto.parse("mailto:a@x.example?subject=Hi%0D%0ABcc%3A%20evil@thief.example"))

        #expect(request.subject.contains("\n") == false)
        #expect(request.subject.contains("\r") == false)
        #expect(request.bcc.isEmpty)
        #expect(request.subject == "Hi  Bcc: evil@thief.example")
    }

    /// Swift reads `\r\n` as one `Character`. Substituting per character
    /// would collapse it to a single space while `\n\r` produced two, so the
    /// guard's output would depend on where grapheme boundaries fell — and a
    /// guard nobody can predict is a guard nobody can test.
    @Test("the line-break guard counts scalars, not grapheme clusters")
    func lineBreakGuardIsScalarWise() throws {
        let crlf = try #require(Mailto.parse("mailto:a@x.example?subject=a%0D%0Ab"))
        let lfcr = try #require(Mailto.parse("mailto:a@x.example?subject=a%0A%0Db"))

        #expect(crlf.subject == "a  b")
        #expect(lfcr.subject == "a  b")
    }

    @Test("a newline in a recipient cannot smuggle a second one in")
    func crlfInRecipientIsFlattened() throws {
        let request = try #require(
            Mailto.parse("mailto:a@x.example%0D%0Abcc%3Aevil@thief.example"))

        #expect(request.to.count == 1)
        #expect(request.to[0].contains("\n") == false)
        // And the flattened result is not an address, so the composer names it
        // back rather than sending to it.
        #expect(RecipientParsing.parse(request.to[0]) == nil)
    }

    /// U+202E reverses how the rest of the line renders, which is how a body
    /// that reads as one thing in the composer arrives as another.
    @Test("invisible reordering characters are stripped from the body")
    func bidiOverridesAreStripped() throws {
        let request = try #require(Mailto.parse("mailto:a@x.example?body=safe%E2%80%AEreversed"))

        #expect(request.body.unicodeScalars.contains("\u{202E}") == false)
        #expect(request.body == "safereversed")
    }

    @Test("a NUL in a body does not reach the editor")
    func nullBytesAreStripped() throws {
        let request = try #require(Mailto.parse("mailto:a@x.example?body=a%00b"))

        #expect(request.body == "ab")
    }

    @Test("newlines and tabs are kept in a body, because they are text")
    func bodyKeepsItsWhitespace() throws {
        let request = try #require(Mailto.parse("mailto:a@x.example?body=one%0Atwo%09three"))

        #expect(request.body == "one\ntwo\tthree")
    }

    @Test("an over-long body is cut and the link says so")
    func overLongBodyIsTrimmed() throws {
        let long = String(repeating: "a", count: Mailto.maximumBodyLength + 500)
        let request = try #require(Mailto.parse("mailto:a@x.example?body=\(long)"))

        #expect(request.body.count == Mailto.maximumBodyLength)
        #expect(request.wasTrimmed)
    }

    @Test("an over-long subject is cut at the line limit an MTA would refuse anyway")
    func overLongSubjectIsTrimmed() throws {
        let long = String(repeating: "s", count: Mailto.maximumSubjectLength + 10)
        let request = try #require(Mailto.parse("mailto:a@x.example?subject=\(long)"))

        #expect(request.subject.count == Mailto.maximumSubjectLength)
        #expect(request.wasTrimmed)
    }

    @Test("a recipient list past the ceiling is cut and the link says so")
    func tooManyRecipientsIsTrimmed() throws {
        let many = (0..<(Mailto.maximumRecipients + 20))
            .map { "a\($0)@x.example" }
            .joined(separator: ",")
        let request = try #require(Mailto.parse("mailto:\(many)"))

        #expect(request.to.count == Mailto.maximumRecipients)
        #expect(request.wasTrimmed)
    }

    @Test("an ordinary link is not marked as trimmed")
    func ordinaryLinkIsNotTrimmed() throws {
        #expect(try #require(Mailto.parse("mailto:a@x.example?body=hello")).wasTrimmed == false)
    }

    @Test("a link that is only junk still parses into something openable")
    func junkStillOpens() throws {
        let request = try #require(Mailto.parse("mailto:????&&&===%%%"))

        #expect(request.to.isEmpty == false || request.isEmpty)
    }

    @Test("surrounding whitespace does not stop a link being recognised")
    func leadingWhitespaceIsTolerated() throws {
        #expect(try #require(Mailto.parse("  mailto:a@x.example  ")).to == ["a@x.example"])
    }

    // MARK: - Writing a recipient field back out

    /// The field is re-split on commas and semicolons. One unreadable
    /// recipient must not become three.
    @Test("an unreadable recipient survives into the field as exactly one entry")
    func unreadableRecipientStaysOneEntry() {
        let field = MailtoRequest.field(from: ["not an address, really; honestly"])

        #expect(RecipientParsing.split(field).count == 1)
        #expect(RecipientParsing.parse(field) == nil)
    }

    @Test("a readable recipient is written back in the form the field expects")
    func readableRecipientRoundTrips() {
        let field = MailtoRequest.field(from: ["Anna <anna@x.example>", "b@y.example"])

        #expect(
            RecipientParsing.addresses(in: field).map(\.email)
                == ["anna@x.example", "b@y.example"])
        #expect(RecipientParsing.addresses(in: field).first?.name == "Anna")
    }

    // MARK: - Routing

    /// A link must reach the shell as the `.compose` request it already knows
    /// how to open, with the rest riding alongside — see ``IntentRouter``.
    @Test("a link sets both halves of the router, and taking one leaves the other")
    @MainActor
    func routerCarriesBothHalves() throws {
        let router = IntentRouter.shared

        router.request(
            mailto: MailtoRequest(to: ["a@x.example"], cc: ["c@z.example"], subject: "Hi"))

        #expect(router.take() == .compose(recipient: "a@x.example", subject: "Hi"))
        #expect(try #require(router.takeMailto()).cc == ["c@z.example"])
        #expect(router.takeMailto() == nil)
    }

    /// The failure this prevents: a composer opened by hand hours later
    /// filling itself in from a link somebody tapped in the morning.
    @Test("an ordinary compose request clears a link that was never opened")
    @MainActor
    func plainComposeClearsAStaleLink() {
        let router = IntentRouter.shared

        router.request(mailto: MailtoRequest(to: ["a@x.example"], body: "unsent"))
        router.request(.compose(recipient: "b@y.example", subject: nil))

        #expect(router.takeMailto() == nil)
        _ = router.take()
    }

    @Test("a link with no subject asks for no subject rather than an empty one")
    @MainActor
    func emptySubjectIsNotCarried() {
        let router = IntentRouter.shared

        router.request(mailto: MailtoRequest(to: ["a@x.example"]))

        #expect(router.take() == .compose(recipient: "a@x.example", subject: nil))
        _ = router.takeMailto()
    }

    // MARK: - Reaching the composer

    /// `@MainActor` because `ComposeModel` is, and a synchronous helper that
    /// builds one from a nonisolated context does not compile under strict
    /// concurrency — the failure this replaces.
    @MainActor
    private static func model() -> ComposeModel {
        ComposeModel(
            kind: .new,
            accountKey: "nas.local/1",
            accountID: AccountID("1"),
            client: JMAPClient(
                discoveryURL: URL(string: "https://nas.local/.well-known/jmap")
                    ?? URL(filePath: "/"),
                credential: .appPassword("plmail_test"),
                transport: MockTransport { request in
                    (Data(), MockTransport.response(for: request))
                }),
            store: SyncStore(modelContainer: MailStack.makeContainer(inMemory: true)),
            outbox: Outbox(serverID: "test-\(UUID().uuidString)"),
            contacts: SilentContacts()
        )
    }

    @Test("a link fills every field the composer has")
    @MainActor
    func linkFillsTheComposer() throws {
        let model = Self.model()

        let link = "mailto:a@x.example?cc=c@z.example&bcc=b@z.example&subject=Hi&body=There"

        model.apply(try #require(Mailto.parse(link)))

        #expect(model.to == "a@x.example")
        #expect(model.cc == "c@z.example")
        #expect(model.bcc == "b@z.example")
        #expect(model.subject == "Hi")
        #expect(String(model.body.characters) == "There")
    }

    /// A `mailto:` body is plain by definition and arrives from a web page.
    /// Handing it to the editor as markup is the difference between a link
    /// that prefills a message and a link that draws one.
    @Test("a body carrying markup reaches the editor as text")
    @MainActor
    func markupInABodyIsNotMarkup() throws {
        let model = Self.model()

        model.apply(
            try #require(Mailto.parse("mailto:a@x.example?body=%3Cb%3Ebold%3C%2Fb%3E")))

        #expect(String(model.body.characters) == "<b>bold</b>")
    }

    /// The failure this prevents: a link tapped by accident and closed again
    /// leaving a draft in the Drafts mailbox on every device.
    @Test("a link does not on its own count as having written anything")
    @MainActor
    func linkDoesNotArmTheAutosave() throws {
        let model = Self.model()

        model.apply(try #require(Mailto.parse("mailto:a@x.example?subject=Hi")))

        #expect(model.isEmpty == false)
        #expect(model.needsCloseConfirmation == false)
    }

    /// ``ComposeModel/appendedSignature`` is only removable while it is still
    /// the suffix of the body; a link that overwrote the body would strand it
    /// and make the next From swap eat a paragraph.
    @Test("a link's body goes in ahead of a signature rather than over it")
    @MainActor
    func linkBodyPrecedesTheSignature() throws {
        let model = Self.model()
        let signature = try #require(ComposeModel.signatureBlock("Anna"))

        model.body = AttributedString(signature)
        model.apply(try #require(Mailto.parse("mailto:a@x.example?body=Hello")))

        #expect(String(model.body.characters) == "Hello" + signature)
    }

    @Test("a blank link opens a composer with nothing in it")
    @MainActor
    func blankLinkLeavesTheComposerEmpty() throws {
        let model = Self.model()

        model.apply(try #require(Mailto.parse("mailto:")))

        #expect(model.isEmpty)
    }
}

/// No address book, so a link test never waits on a permission prompt.
private struct SilentContacts: ContactSource {
    func addresses(matching fragment: String) async -> [EmailAddress] { [] }
}
