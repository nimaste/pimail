import Foundation

/// Reading a stored HTML signature well enough to decide whether a plain-text
/// box may edit it.
///
/// The server keeps **one** signature, in HTML; `textSignature` is a rendering
/// of it, not a second value. So a settings screen offering a plain-text field
/// has a problem the composer does not: saving that field replaces the stored
/// HTML, and a signature written in the web interface with a link and a logo
/// would come back as its own flattened text the first time anyone opened the
/// editor and pressed Save without changing anything.
///
/// The defence is to ask first whether the stored HTML *is* plain text. When it
/// is — the overwhelmingly common case, since that is what this screen and
/// every text-only client write — the plain box is lossless and is offered.
/// When it is not, the signature is shown and not edited, with the reason said
/// out loud, plus one deliberate route to replace it. Guessing wrong in the
/// other direction silently destroys something the user built elsewhere.
public enum SignatureText {
    /// Tags that carry no formatting a plain-text field would lose.
    ///
    /// A line break is a newline and a paragraph is a blank line; both survive
    /// the round trip through text intact. Everything else — a link, an image,
    /// a colour, a table — does not, which is what makes this list the whole
    /// test rather than a convenience.
    private static let losslessTags: Set<String> = ["br", "p", "/p", "div", "/div"]

    /// Whether a plain-text editor can hold this signature without losing
    /// anything.
    ///
    /// Empty counts as plain: an address that signs with nothing is editable,
    /// and refusing to edit it would leave the one case where there is
    /// certainly nothing to lose as the one case that cannot be changed.
    public static func isPlainTextEquivalent(_ html: String?) -> Bool {
        guard let html, html.isEmpty == false else { return true }

        var inTag = false
        var tag = ""

        for character in html {
            if character == "<" {
                inTag = true
                tag = ""
            } else if character == ">" {
                guard inTag else { continue }

                inTag = false

                // `<br />` and `<BR>` are the same tag; the attributes of a
                // `<p style=…>` are formatting and make it not lossless.
                let name = tag.trimmingCharacters(in: .whitespaces).lowercased()
                // The self-closing slash goes first and the whitespace second,
                // or `<br />` — which is the spelling half the world writes —
                // reads as a tag with an attribute and is refused.
                let bare = (name.hasSuffix("/") ? String(name.dropLast()) : name)
                    .trimmingCharacters(in: .whitespaces)

                if bare.contains(" ") { return false }
                if losslessTags.contains(bare) == false { return false }
            } else if inTag {
                tag.append(character)
            }
        }

        return true
    }

    /// The plain-text rendering of a stored signature, for a text field.
    ///
    /// Deliberately not an HTML parser: this runs only over signatures
    /// ``isPlainTextEquivalent(_:)`` has already vouched for, where the tags
    /// are line breaks and the rest is escaped text. Entities are unescaped
    /// last so that a signature containing `&lt;b&gt;` comes back as the five
    /// characters the user typed rather than as markup.
    public static func plainText(fromHTML html: String?) -> String {
        guard let html, html.isEmpty == false else { return "" }

        var text = html

        for tag in ["<br>", "<br/>", "<br />", "<BR>", "<BR/>", "<BR />"] {
            text = text.replacingOccurrences(of: tag, with: "\n")
        }

        text = text.replacingOccurrences(of: "</p>", with: "\n\n")
        text = text.replacingOccurrences(of: "</div>", with: "\n")

        for tag in ["<p>", "<div>", "</P>", "<P>"] {
            text = text.replacingOccurrences(of: tag, with: "")
        }

        // Ampersand last, or `&amp;lt;` — a signature that really does contain
        // the text "&lt;" — would decode twice and come back as "<".
        for (entity, character) in [
            ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#039;", "'"),
            ("&#39;", "'"), ("&nbsp;", " "), ("&amp;", "&"),
        ] {
            text = text.replacingOccurrences(of: entity, with: character)
        }

        return text
    }

    /// Whether a typed signature has anything in it.
    ///
    /// Whitespace-only is nothing: saving it would append a blank line to every
    /// message sent from the address, which reads as a bug in the composer
    /// rather than as a signature the user left empty.
    public static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
