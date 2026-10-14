import Testing

@testable import PLMailCore

/// The snippet is the one place server-side message content is handed back as
/// markup. Everything here is about that: getting the hits out, and getting
/// nothing else out.
@Suite("Snippet text")
struct SnippetTextTests {
    @Test("a hit becomes a highlighted run")
    func highlights() {
        let runs = SnippetText.runs(from: "Please arrange the <mark>wire</mark> transfer")

        #expect(
            runs == [
                .init(text: "Please arrange the ", isHighlighted: false),
                .init(text: "wire", isHighlighted: true),
                .init(text: " transfer", isHighlighted: false),
            ])
    }

    @Test("several hits in one snippet")
    func multiple() {
        let runs = SnippetText.runs(from: "<mark>wire</mark> and <mark>transfer</mark>")

        #expect(runs.filter(\.isHighlighted).map(\.text) == ["wire", "transfer"])
        #expect(
            SnippetText.plain(from: "<mark>wire</mark> and <mark>transfer</mark>")
                == "wire and transfer")
    }

    /// The whole reason this is not passed to a web view or rendered as HTML.
    /// A sender who writes a script tag has it escaped on the way out, and it
    /// has to come back as the characters they typed — not as markup, and not
    /// mangled.
    @Test("escaped markup in the message stays text")
    func escapedMarkupIsText() {
        let runs = SnippetText.runs(
            from: "he wrote &lt;script&gt;alert(1)&lt;/script&gt; in the <mark>body</mark>")

        #expect(
            runs == [
                .init(text: "he wrote <script>alert(1)</script> in the ", isHighlighted: false),
                .init(text: "body", isHighlighted: true),
            ])
    }

    /// `&amp;` decoding last, or a sender who actually typed `&lt;` gets it
    /// turned into a `<` by a second pass.
    @Test("a doubly escaped entity is only decoded once")
    func doubleEscaping() {
        #expect(SnippetText.unescape("&amp;lt;") == "&lt;")
        #expect(SnippetText.unescape("a &amp; b") == "a & b")
        #expect(SnippetText.unescape("&quot;quoted&quot;") == "\"quoted\"")
    }

    /// Anything that is not one of the five entities the server produces is
    /// something the sender typed. Decoding it would change the message.
    @Test("other entity-looking text is left alone")
    func leavesOtherEntities() {
        #expect(SnippetText.unescape("100 &euro; and &nbsp; here") == "100 &euro; and &nbsp; here")
    }

    @Test("a snippet with no hit is one plain run")
    func noHit() {
        let runs = SnippetText.runs(from: "nothing matched here")

        #expect(runs == [.init(text: "nothing matched here", isHighlighted: false)])
    }

    /// Losing the tail of a snippet is worse than highlighting too much of it.
    @Test("an unclosed mark keeps the rest of the text")
    func unclosed() {
        let runs = SnippetText.runs(from: "start <mark>rest of it")

        #expect(SnippetText.plain(from: "start <mark>rest of it") == "start rest of it")
        #expect(runs.last?.isHighlighted == true)
    }

    @Test("an empty snippet produces no runs")
    func empty() {
        #expect(SnippetText.runs(from: "").isEmpty)
    }
}
