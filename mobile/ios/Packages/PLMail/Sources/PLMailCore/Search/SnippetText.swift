import Foundation

/// Turns a server snippet into something a label can draw.
///
/// The wire format is HTML: the message's own text escaped, with `<mark>`
/// around each hit. It must never reach a web view or be shown raw — this
/// converts it to an `AttributedString` with the hits marked as a run, which is
/// both safer and what a list row wants anyway.
///
/// Deliberately not a general HTML parser. The only markup the server emits
/// here is `<mark>`; anything else in the string is message content that was
/// escaped on the way out, and treating it as markup would be the bug this
/// avoids. A stray tag therefore survives as literal text.
public enum SnippetText {
    /// The runs of a snippet, in order.
    public struct Run: Equatable, Sendable {
        public var text: String
        public var isHighlighted: Bool
    }

    /// Splits on `<mark>` boundaries and unescapes each piece.
    public static func runs(from html: String) -> [Run] {
        var runs: [Run] = []
        var remainder = Substring(html)

        while let open = remainder.range(of: "<mark>") {
            let before = remainder[remainder.startIndex..<open.lowerBound]

            if before.isEmpty == false {
                runs.append(Run(text: unescape(String(before)), isHighlighted: false))
            }

            let afterOpen = remainder[open.upperBound...]

            guard let close = afterOpen.range(of: "</mark>") else {
                // An unclosed tag: take the rest as highlighted rather than
                // dropping it. Losing the tail of a snippet is worse than
                // highlighting a little too much of it.
                runs.append(Run(text: unescape(String(afterOpen)), isHighlighted: true))

                return runs
            }

            let marked = afterOpen[afterOpen.startIndex..<close.lowerBound]

            if marked.isEmpty == false {
                runs.append(Run(text: unescape(String(marked)), isHighlighted: true))
            }

            remainder = afterOpen[close.upperBound...]
        }

        if remainder.isEmpty == false {
            runs.append(Run(text: unescape(String(remainder)), isHighlighted: false))
        }

        return runs
    }

    /// The five entities PHP's `htmlspecialchars` produces, and no others.
    ///
    /// A general entity table would be wrong here: anything else that looks
    /// like an entity is literal text the sender wrote, and decoding it would
    /// change the message.
    ///
    /// `&amp;` is applied last so that `&amp;lt;` — a sender who actually
    /// typed `&lt;` — comes out as `&lt;` rather than being decoded twice into
    /// a `<`.
    static func unescape(_ text: String) -> String {
        var result = text

        for (entity, character) in [
            ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#039;", "'"), ("&#39;", "'"),
        ] {
            result = result.replacingOccurrences(of: entity, with: character)
        }

        return result.replacingOccurrences(of: "&amp;", with: "&")
    }

    /// The plain text of a snippet, with the markup removed.
    public static func plain(from html: String) -> String {
        runs(from: html).map(\.text).joined()
    }
}
