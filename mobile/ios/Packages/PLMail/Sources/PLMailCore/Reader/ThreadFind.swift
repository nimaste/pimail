import Foundation
import Observation

/// Finding a phrase inside one open conversation.
///
/// Two decisions shape everything here.
///
/// **The count is native and complete.** Matches are computed from the message
/// snapshots, including the ones folded away behind "earlier messages" and the
/// ones whose body has never been rendered. If the count came from the views
/// that happen to be on screen, "3 of 12" would change as you scrolled, which
/// is the one thing a match counter must never do.
///
/// **The web view is told where to highlight, never asked to search.** A
/// message body is HTML in a `WKWebView`, so the highlight has to happen in the
/// DOM. The obvious split — native counts, JavaScript searches — has the two
/// sides disagreeing about case folding, entity decoding and collapsed
/// whitespace, and a disagreement there means "match 3 of 12" scrolls to
/// nothing. So only one side ever matches: this one. ``plainText(fromHTML:)``
/// projects the message to the same flat string the DOM walker builds, matches
/// are reported as UTF-16 offsets into it, and the injected script's only job is
/// to map those offsets back onto text nodes.
public enum ThreadFind {
    /// The parts of a message a find looks at.
    ///
    /// The thread's subject is deliberately not among them: it is one line at
    /// the top of the screen that the reader can already see, and counting it
    /// as a match would put an entry in the navigation order that goes nowhere
    /// anyone needed to be taken.
    public enum Field: String, Hashable, Sendable, CaseIterable {
        case sender
        case recipients
        case body
    }

    /// Occurrences of `query` in `text`.
    ///
    /// Case- and diacritic-insensitive, because someone typing into a find bar
    /// on a phone keyboard is not going to reach for the umlaut, and a search
    /// that misses "Grüße" when you type "grusse" reads as a broken search
    /// rather than a precise one.
    public static func ranges(of query: String, in text: String) -> [Range<String.Index>] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard needle.isEmpty == false, text.isEmpty == false else { return [] }

        var found: [Range<String.Index>] = []
        var searchFrom = text.startIndex

        while searchFrom < text.endIndex,
            let range = text.range(
                of: needle,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: searchFrom..<text.endIndex
            )
        {
            found.append(range)

            // Diacritic-insensitive matching can return an empty range for some
            // inputs, and resuming at its upper bound would then never advance.
            searchFrom = range.isEmpty ? text.index(after: range.lowerBound) : range.upperBound
        }

        return found
    }

    /// What one field of a message contributes to a find.
    ///
    /// For an HTML body this is the flat projection the DOM will agree with.
    /// For a plain-text body it is the text itself, unnormalised, because that
    /// one is rendered by SwiftUI and the ranges have to land in the string
    /// actually on screen.
    public static func text(_ field: Field, of message: MessageSnapshot) -> String {
        switch field {
        case .sender:
            message.displayName

        case .recipients:
            message.to.map(\.displayName).joined(separator: ", ")

        case .body:
            if let html = message.htmlBody, html.isEmpty == false {
                plainText(fromHTML: html)
            } else {
                message.textBody ?? ""
            }
        }
    }

    // MARK: - Projection

    /// The text a browser would report for this markup.
    ///
    /// Not a parser and not trying to be one: it drops markup and keeps
    /// characters, which is all the DOM's own `textContent` does. The rules it
    /// does implement are the ones where a browser and a naïve tag-stripper
    /// disagree, and every one of them would show up as a highlight landing on
    /// the wrong word:
    ///
    /// - comments and the contents of `script` and `style` are not text;
    /// - `>` inside a quoted attribute value does not end the tag;
    /// - entities are decoded, because the DOM hands back the character;
    /// - runs of whitespace collapse to one space, and a non-breaking space is
    ///   normalised into that run — otherwise a phrase split across two source
    ///   lines is unfindable, which in mail is most of them.
    ///
    /// Element boundaries contribute nothing, again matching `textContent`: two
    /// adjacent `<div>`s read as one run. That is occasionally surprising and
    /// always consistent, and consistency is the property this is for.
    public static func plainText(fromHTML html: String) -> String {
        collapsingWhitespace(decodingEntities(strippingMarkup(html)))
    }

    private static func strippingMarkup(_ html: String) -> String {
        var out = ""
        var index = html.startIndex

        while index < html.endIndex {
            guard html[index] == "<" else {
                out.append(html[index])
                index = html.index(after: index)
                continue
            }

            if html[index...].hasPrefix("<!--") {
                index = skip(in: html, from: index, past: "-->")
                continue
            }

            if let raw = ["script", "style"].first(where: { opensElement($0, in: html, at: index) })
            {
                let afterTag = skipTag(in: html, from: index)
                index = skip(in: html, from: afterTag, past: "</\(raw)")

                // The closing tag's own `>`, plus anything a sloppy sender put
                // between the name and it.
                index = skip(in: html, from: index, past: ">")
                continue
            }

            index = skipTag(in: html, from: index)
        }

        return out
    }

    /// Whether a tag for `name` starts here, as opposed to one whose name
    /// merely begins with it — `<styled>` is not `<style>`.
    private static func opensElement(
        _ name: String, in html: String, at index: String.Index
    )
        -> Bool
    {
        // Only the name's worth of characters is folded. Lowercasing the rest
        // of the document instead is the same answer and quadratic in the
        // length of the message, which on a long newsletter is felt.
        let rest = html[index...].dropFirst()
        let candidate = rest.prefix(name.count)

        guard candidate.count == name.count, candidate.lowercased() == name else { return false }

        guard let next = rest.dropFirst(name.count).first else { return false }

        return next == ">" || next == "/" || next.isWhitespace
    }

    /// Past the tag starting at `index`, honouring quoted attribute values.
    private static func skipTag(in html: String, from index: String.Index) -> String.Index {
        var cursor = html.index(after: index)
        var quote: Character?

        while cursor < html.endIndex {
            let character = html[cursor]
            cursor = html.index(after: cursor)

            if let open = quote {
                if character == open { quote = nil }
                continue
            }

            if character == "\"" || character == "'" {
                quote = character
            } else if character == ">" {
                return cursor
            }
        }

        return html.endIndex
    }

    private static func skip(
        in html: String, from index: String.Index, past marker: String
    )
        -> String.Index
    {
        guard
            let range = html.range(
                of: marker, options: .caseInsensitive, range: index..<html.endIndex)
        else { return html.endIndex }

        return range.upperBound
    }

    /// The entities a mail body actually carries.
    ///
    /// `&amp;` is applied last so a sender who wrote `&amp;lt;` gets `&lt;`
    /// back rather than having it decoded twice into a `<`.
    private static func decodingEntities(_ text: String) -> String {
        var result = text

        for (entity, character) in [
            ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"),
            ("&#039;", "'"), ("&#39;", "'"), ("&#34;", "\""), ("&nbsp;", "\u{00A0}"),
        ] {
            result = result.replacingOccurrences(of: entity, with: character)
        }

        return result.replacingOccurrences(of: "&amp;", with: "&")
    }

    /// The exact rule the injected script repeats, character for character.
    ///
    /// Kept as its own function rather than a regular expression so that the
    /// JavaScript can be a transcription of it. A regular expression here and a
    /// different one there is how the two projections drift apart.
    static func collapsingWhitespace(_ text: String) -> String {
        var out = ""

        for character in text {
            let isSpace =
                character == " " || character == "\u{00A0}" || character.isNewline
                || character == "\t" || character == "\u{0B}" || character == "\u{0C}"
                || character == "\r"

            if isSpace {
                if out.isEmpty == false, out.last != " " { out.append(" ") }
            } else {
                out.append(character)
            }
        }

        if out.last == " " { out.removeLast() }

        return out
    }
}

/// One hit, and where to draw it.
public struct ThreadFindMatch: Hashable, Sendable, Identifiable {
    public var messageID: String
    public var field: ThreadFind.Field
    /// Which occurrence within this message and field, counted from zero. The
    /// web view is told the ordinal of the current match rather than its
    /// offsets, because that is what "emphasise this one of the ones you are
    /// already highlighting" needs.
    public var occurrence: Int
    /// UTF-16 offsets into ``ThreadFind/text(_:of:)`` for the same field —
    /// the coordinates the DOM walker speaks.
    public var start: Int
    public var length: Int

    public var id: String { "\(messageID)#\(field.rawValue)#\(occurrence)" }
}

/// The find bar's state for one open conversation.
@MainActor
@Observable
public final class ThreadFindModel {
    /// What was typed. Empty means the bar is open with nothing to find, which
    /// is a different state from the bar being closed — the reader owns that.
    public var query: String = "" {
        didSet {
            guard query != oldValue else { return }
            recompute()
        }
    }

    public private(set) var matches: [ThreadFindMatch] = []
    /// Which match is current. Always a valid index while ``matches`` is
    /// non-empty; meaningless and ignored when it is empty.
    public private(set) var currentIndex = 0

    /// Projections, kept between keystrokes. Scanning six HTML bodies per typed
    /// character is affordable, but it is also avoidable, and the whole point
    /// of a find bar is that it keeps up with typing.
    private var texts: [String: [ThreadFind.Field: String]] = [:]
    private var order: [String] = []

    public init() {}

    /// Re-reads the thread. Called whenever the loader publishes messages, so a
    /// reply arriving mid-search is searched too.
    public func update(messages: [MessageSnapshot]) {
        order = messages.map(\.id)
        texts = Dictionary(
            uniqueKeysWithValues: messages.map { message in
                (
                    message.id,
                    Dictionary(
                        uniqueKeysWithValues: ThreadFind.Field.allCases.map {
                            ($0, ThreadFind.text($0, of: message))
                        })
                )
            })

        recompute()
    }

    public var current: ThreadFindMatch? {
        matches.indices.contains(currentIndex) ? matches[currentIndex] : nil
    }

    public var hasQuery: Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    /// Wraps at both ends, the way every find bar does: the alternative is a
    /// disabled button on the last match, and nobody has ever wanted that.
    public func next() {
        guard matches.isEmpty == false else { return }
        currentIndex = (currentIndex + 1) % matches.count
    }

    public func previous() {
        guard matches.isEmpty == false else { return }
        currentIndex = (currentIndex + matches.count - 1) % matches.count
    }

    /// Occurrences of the query in an arbitrary string, for the views that draw
    /// their own text and can highlight it directly.
    public func ranges(in text: String) -> [Range<String.Index>] {
        ThreadFind.ranges(of: query, in: text)
    }

    /// The body matches for one message, as offsets the injected script can map.
    public func bodyMatches(in messageID: String) -> [ThreadFindMatch] {
        matches.filter { $0.messageID == messageID && $0.field == .body }
    }

    /// Which occurrence in this message and field is the current one, if the
    /// current one is here at all.
    public func currentOccurrence(in messageID: String, field: ThreadFind.Field) -> Int? {
        guard let current, current.messageID == messageID, current.field == field else {
            return nil
        }

        return current.occurrence
    }

    /// "3 of 12", or why there is no number.
    public var statusText: String {
        guard hasQuery else { return "" }

        guard matches.isEmpty == false else {
            return String(localized: "No matches", bundle: .module)
        }

        return String(
            localized: "\(currentIndex + 1) of \(matches.count)",
            bundle: .module,
            comment: "Position of the current find-in-thread match, and how many there are.")
    }

    private func recompute() {
        let previous = current

        matches = order.flatMap { messageID in
            ThreadFind.Field.allCases.flatMap { field -> [ThreadFindMatch] in
                let text = texts[messageID]?[field] ?? ""

                return ThreadFind.ranges(of: query, in: text).enumerated().map {
                    occurrence, range in
                    let utf16 = NSRange(range, in: text)

                    return ThreadFindMatch(
                        messageID: messageID,
                        field: field,
                        occurrence: occurrence,
                        start: utf16.location,
                        length: utf16.length
                    )
                }
            }
        }

        // Typing another letter narrows the results; jumping back to the first
        // one would drag the reader away from the passage they were already
        // looking at. Hold the position when the match under the cursor is
        // still a match, and start again when it is not.
        if let previous, let held = matches.firstIndex(where: { $0.id == previous.id }) {
            currentIndex = held
        } else {
            currentIndex = 0
        }
    }
}
