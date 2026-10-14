import Foundation
import JMAPKit
import Testing

@testable import PLMailCore

/// The projection is the load-bearing part: the injected highlighter maps
/// offsets into it back onto DOM text nodes, so anywhere this disagrees with
/// what a browser calls the document's text, a highlight lands on the wrong
/// word. Most of these are cases where a naïve tag-stripper and a browser part
/// company.
@Suite("Find within a thread")
struct ThreadFindTests {
    private func message(
        id: String = "m1",
        from: String = "Dana Whitfield",
        to: [EmailAddress] = [EmailAddress(name: "Alex Rowe", email: "alex@example.com")],
        html: String? = nil,
        text: String? = nil
    ) -> MessageSnapshot {
        MessageSnapshot(
            emailID: id,
            accountKey: "acct",
            blobID: nil,
            subject: "Roof repair quote",
            fromName: from,
            fromAddress: "dana@example.com",
            to: to,
            cc: [],
            receivedAt: Date(timeIntervalSince1970: 1_750_000_000),
            messageID: nil,
            references: [],
            preview: "",
            isSeen: true,
            isFlagged: false,
            isDraft: false,
            htmlBody: html,
            textBody: text,
            hasBody: true,
            attachments: [],
            inlineParts: []
        )
    }

    // MARK: - Projection

    @Test("markup contributes no characters")
    func stripsTags() {
        #expect(ThreadFind.plainText(fromHTML: "<p>Roof <b>repair</b></p>") == "Roof repair")
    }

    @Test("adjacent blocks read as one run, as textContent does")
    func noBoundarySeparator() {
        #expect(ThreadFind.plainText(fromHTML: "<div>Roof</div><div>repair</div>") == "Roofrepair")
    }

    @Test("a quoted attribute value may contain the tag terminator")
    func quotedAttributes() {
        #expect(
            ThreadFind.plainText(fromHTML: "<a title=\"a > b\" href='x>y'>Quote</a>") == "Quote")
    }

    @Test("comments are not text")
    func comments() {
        #expect(ThreadFind.plainText(fromHTML: "Roof<!-- hidden repair -->quote") == "Roofquote")
    }

    @Test("script and style contents are not text")
    func rawTextElements() {
        #expect(
            ThreadFind.plainText(fromHTML: "<style>p { color: red }</style>Roof") == "Roof")
        #expect(
            ThreadFind.plainText(fromHTML: "<script>var repair = 1;</script>Roof") == "Roof")
    }

    /// `<styled>` is not `<style>`, and treating it as one swallows the rest of
    /// the message up to a closing tag that never comes.
    @Test("an element whose name merely starts with style is not style")
    func rawTextPrefixIsNotEnough() {
        #expect(ThreadFind.plainText(fromHTML: "<styles>Roof</styles>") == "Roof")
    }

    @Test("entities decode to their character")
    func entities() {
        let decoded = ThreadFind.plainText(fromHTML: "Bell &amp; Sons &lt;quote&gt;")
        #expect(decoded == "Bell & Sons <quote>")
    }

    /// A sender who typed `&lt;` literally gets it back, rather than having it
    /// decoded twice into a `<`.
    @Test("an escaped entity is decoded once")
    func doubleEscaping() {
        #expect(ThreadFind.plainText(fromHTML: "&amp;lt;") == "&lt;")
    }

    @Test("whitespace collapses across source lines")
    func collapsesWhitespace() {
        #expect(
            ThreadFind.plainText(fromHTML: "<p>Roof\n   repair\tquote</p>") == "Roof repair quote")
    }

    @Test("a non-breaking space collapses into the run")
    func nonBreakingSpace() {
        #expect(ThreadFind.plainText(fromHTML: "Roof&nbsp;&nbsp;repair") == "Roof repair")
    }

    @Test("leading and trailing whitespace is dropped")
    func trims() {
        #expect(ThreadFind.plainText(fromHTML: "  <p>  Roof  </p>  ") == "Roof")
    }

    @Test("an unterminated tag does not spill into the text")
    func unterminatedTag() {
        #expect(ThreadFind.plainText(fromHTML: "Roof<b class=") == "Roof")
    }

    // MARK: - Matching

    @Test("matching ignores case and diacritics")
    func folding() {
        #expect(ThreadFind.ranges(of: "grusse", in: "Viele Grüße").count == 1)
        #expect(ThreadFind.ranges(of: "ROOF", in: "roof Roof").count == 2)
    }

    @Test("overlapping candidates advance past the match")
    func advances() {
        #expect(ThreadFind.ranges(of: "aa", in: "aaaa").count == 2)
    }

    @Test("an empty or whitespace query matches nothing")
    func emptyQuery() {
        #expect(ThreadFind.ranges(of: "", in: "Roof").isEmpty)
        #expect(ThreadFind.ranges(of: "   ", in: "Roof").isEmpty)
    }

    @Test("the query is trimmed before matching")
    func trimsQuery() {
        #expect(ThreadFind.ranges(of: "  roof  ", in: "Roof repair").count == 1)
    }

    // MARK: - Offsets

    /// The contract with the injected script: offsets are UTF-16, into the
    /// projection. An emoji earlier in the body has to move them by two.
    @Test("body offsets are UTF-16 into the projection")
    @MainActor
    func utf16Offsets() {
        let model = ThreadFindModel()
        model.update(messages: [message(html: "<p>🏠 roof</p>")])
        model.query = "roof"

        let body = try? #require(model.bodyMatches(in: "acct#m1").first)

        #expect(body?.start == 3)
        #expect(body?.length == 4)
    }

    // MARK: - Model

    @Test("matches run in thread order, sender before body")
    @MainActor
    func ordering() {
        let model = ThreadFindModel()
        model.update(messages: [
            message(id: "m1", from: "Roofers Ltd", html: "<p>the roof</p>"),
            message(id: "m2", from: "Dana", html: "<p>roof again</p>"),
        ])
        model.query = "roof"

        #expect(
            model.matches.map(\.id) == [
                "acct#m1#sender#0", "acct#m1#body#0", "acct#m2#body#0",
            ])
    }

    @Test("recipients are searched")
    @MainActor
    func searchesRecipients() {
        let model = ThreadFindModel()
        model.update(messages: [
            message(to: [EmailAddress(name: "Priya Raman", email: "priya@example.com")])
        ])
        model.query = "priya"

        #expect(model.matches.map(\.field) == [.recipients])
    }

    @Test("a plain-text body is searched unnormalised")
    @MainActor
    func plainTextBody() {
        let model = ThreadFindModel()
        model.update(messages: [message(html: nil, text: "Roof\n   repair")])
        model.query = "repair"

        // Offsets have to land in the string SwiftUI is drawing, which still
        // has its newline and its indentation.
        #expect(model.matches.first?.start == 8)
    }

    @Test("next and previous wrap at both ends")
    @MainActor
    func wraps() {
        let model = ThreadFindModel()
        model.update(messages: [message(html: "<p>roof roof roof</p>")])
        model.query = "roof"

        #expect(model.matches.count == 3)

        model.previous()
        #expect(model.currentIndex == 2)

        model.next()
        #expect(model.currentIndex == 0)
    }

    /// Typing another letter must not drag the reader back to the top of the
    /// thread when the passage they are looking at still matches.
    @Test("narrowing the query holds the current match")
    @MainActor
    func holdsPosition() {
        let model = ThreadFindModel()
        model.update(messages: [
            message(id: "m1", html: "<p>roofing</p>"),
            message(id: "m2", html: "<p>roofing</p>"),
        ])
        model.query = "roof"
        model.next()

        #expect(model.current?.messageID == "acct#m2")

        model.query = "roofi"

        #expect(model.current?.messageID == "acct#m2")
    }

    @Test("a query that no longer matches starts again from the first")
    @MainActor
    func resetsWhenLost() {
        let model = ThreadFindModel()
        model.update(messages: [
            message(id: "m1", html: "<p>roof</p>"),
            message(id: "m2", html: "<p>roof repair</p>"),
        ])
        model.query = "roof"
        model.next()
        model.query = "roof repair"

        #expect(model.currentIndex == 0)
        #expect(model.current?.messageID == "acct#m2")
    }

    @Test("the current occurrence is reported only for the message holding it")
    @MainActor
    func currentOccurrence() {
        let model = ThreadFindModel()
        model.update(messages: [
            message(id: "m1", html: "<p>roof roof</p>"),
            message(id: "m2", html: "<p>roof</p>"),
        ])
        model.query = "roof"
        model.next()

        #expect(model.currentOccurrence(in: "acct#m1", field: .body) == 1)
        #expect(model.currentOccurrence(in: "acct#m2", field: .body) == nil)
    }

    @Test("a reply arriving mid-search is searched too")
    @MainActor
    func rescansOnUpdate() {
        let model = ThreadFindModel()
        model.update(messages: [message(id: "m1", html: "<p>roof</p>")])
        model.query = "roof"

        #expect(model.matches.count == 1)

        model.update(messages: [
            message(id: "m1", html: "<p>roof</p>"),
            message(id: "m2", html: "<p>roof</p>"),
        ])

        #expect(model.matches.count == 2)
    }

    @Test("status text counts from one, and says when there is nothing")
    @MainActor
    func status() {
        let model = ThreadFindModel()
        model.update(messages: [message(html: "<p>roof roof</p>")])

        #expect(model.statusText.isEmpty)

        model.query = "roof"
        #expect(model.statusText.contains("1"))
        #expect(model.statusText.contains("2"))

        model.query = "chimney"
        #expect(model.matches.isEmpty)
        #expect(model.statusText.isEmpty == false)
    }
}
