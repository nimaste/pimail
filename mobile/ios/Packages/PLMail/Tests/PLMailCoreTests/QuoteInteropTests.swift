import Foundation
import Testing

@testable import PLMailCore

/// Splitting a draft written somewhere else back into "what I wrote" and "what
/// I am answering".
///
/// The marker is the obvious signal and the wrong one to depend on:
/// `data-quoted` is a `data-` attribute, and the server's sanitiser drops every
/// one of those from a stored draft body. What survives is the inline `style`
/// on the wrapper, because `style` is allowed — so after one save the styling
/// is the only signal left.
@Suite("Quote interop")
struct QuoteInteropTests {
    /// What plMail's web composer writes, before it has been saved once.
    private let freshFromTheBrowser = """
        <div>My answer.</div>\
        <div data-quoted="1" style="border-top:1px solid #e0e0e0;font-size:0.85em">\
        <div>On 3 March, Ada wrote:</div>\
        <blockquote><div>Tuesday?</div></blockquote></div>
        """

    /// The same draft after one round trip through `Email/set`.
    private let afterOneSave = """
        <div>My answer.</div>\
        <div style="border-top:1px solid #e0e0e0;font-size:0.85em">\
        <div>On 3 March, Ada wrote:</div>\
        <blockquote><div>Tuesday?</div></blockquote></div>
        """

    @Test("A browser-written draft splits at the wrapper, not inside it")
    func splitsAtTheMarker() {
        let split = MailHTML.splitQuote(fromHTML: freshFromTheBrowser)

        #expect(split.body == "<div>My answer.</div>")
        // The attribution line belongs with the quote. Leaving it in the
        // editable body showed "On 3 March, Ada wrote:" as text the user could
        // type over, above a quote chip.
        #expect(split.quote?.contains("Ada wrote:") == true)
    }

    @Test("The same draft still splits once the marker has been sanitised away")
    func splitsOnTheStyleThatSurvives() {
        let split = MailHTML.splitQuote(fromHTML: afterOneSave)

        #expect(split.body == "<div>My answer.</div>")
        #expect(split.quote?.contains("Tuesday?") == true)
    }

    /// The other half of the same rule: a wrapper signal with no blockquote
    /// under it is a styled message, not a quote, and cutting there would hide
    /// something somebody wrote.
    @Test("A styled body with no blockquote is not mistaken for a quote")
    func styleAloneIsNotAQuote() {
        let html = "<div style=\"border-top:1px solid #ccc\">A rule, then text.</div>"

        #expect(MailHTML.splitQuote(fromHTML: html).quote == nil)
    }

    @Test("What this client emits is what it can read back")
    func ownQuoteRoundTrips() {
        let quote = MailHTML.quote(
            author: "Ada", date: Date(timeIntervalSince1970: 0),
            html: "<div>Tuesday?</div>", text: nil)
        let split = MailHTML.splitQuote(fromHTML: "<div>My answer.</div>" + quote)

        #expect(split.body == "<div>My answer.</div>")
        #expect(split.quote == quote)
    }

    /// The durable half. Emitting only the marker would work for one save and
    /// then stop, and nothing would report that it had.
    @Test("The emitted wrapper carries the styles as well as the marker")
    func emittedWrapperCarriesStyle() {
        let quote = MailHTML.quote(author: "Ada", date: nil, html: "<div>x</div>", text: nil)

        #expect(quote.contains("data-quoted=\"1\""))

        for marker in MailHTML.quoteStyleMarkers {
            #expect(quote.contains(marker))
        }
    }

    @Test("A forward is introduced by a header block rather than by an attribution")
    func forwardWrapper() {
        let forwarded = MailHTML.forwarded(
            block: ReplyDrafting.forwardBlock(
                from: "Ada", date: nil, subject: "Numbers", to: [], cc: []),
            html: "<div>x</div>",
            text: nil)

        #expect(forwarded.contains("Forwarded message"))
        #expect(forwarded.contains("wrote:") == false)
        #expect(MailHTML.splitQuote(fromHTML: "<div>FYI</div>" + forwarded).quote == forwarded)
    }
}
