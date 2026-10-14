#if os(iOS)

public import PLMailCore

import SwiftUI

extension AttributeScopes {
    /// Exactly what the composer can produce, and nothing else.
    ///
    /// Constraining the editor to this scope is what makes a paste from a web
    /// page safe: font sizes, colours and background fills are dropped on the
    /// way in, so what is on screen is always something this app can serialise.
    /// Without it, pasted text would look formatted and arrive plain, and the
    /// sender would have no way to know.
    struct MailEditorAttributes: AttributeScope {
        let inlineStyle: MailInlineStyleAttribute
        let font: AttributeScopes.SwiftUIAttributes.FontAttribute
        let underlineStyle: AttributeScopes.SwiftUIAttributes.UnderlineStyleAttribute
        let strikethroughStyle: AttributeScopes.SwiftUIAttributes.StrikethroughStyleAttribute
        let link: AttributeScopes.FoundationAttributes.LinkAttribute
    }
}

/// The body field, with formatting.
///
/// **The awkward part, and why this file exists.** iOS 26's rich `TextEditor`
/// records bold and italic in `SwiftUI.Font`, which cannot be inspected — there
/// is no `font.isBold`. It can only be compared against a font you constructed
/// yourself. So the editor is pinned to a known base font, and after every edit
/// each run's font is matched against the handful of values that base can
/// produce and rewritten into ``MailInlineStyle``, which the serialiser reads.
///
/// The alternative — keeping our own attribute as the source of truth and
/// writing the font from it — was tried first and is worse: ⌘B, the edit menu
/// and paste all write the font directly, and none of them would have gone
/// through us. Deriving in this direction means every route into the editor
/// works, including ones Apple adds later.
struct RichTextEditor: View {
    @Binding var text: AttributedString
    @Binding var selection: AttributedTextSelection

    var body: some View {
        TextEditor(text: $text, selection: $selection)
            // Pinned, because the whole scheme rests on knowing what plain
            // looks like. `.body` is a semantic font, so this still scales with
            // Dynamic Type — it is the traits that are being pinned, not a size.
            .font(.body)
            .attributedTextFormattingDefinition(AttributeScopes.MailEditorAttributes.self)
            .onChange(of: text) { _, _ in
                let normalized = RichTextEditor.normalized(text)

                // Guarded: assigning unconditionally would re-enter this on
                // every keystroke, and the editor would fight the cursor.
                if normalized != text { text = normalized }
            }
    }

    // MARK: - Normalisation

    /// Every font this editor can legitimately be in.
    ///
    /// Both orderings of bold+italic are listed because they are genuinely
    /// different values — `Font.body.bold().italic()` does not compare equal to
    /// `Font.body.italic().bold()`, and which one you get depends on the order
    /// the user pressed the keys.
    private static let recognised: [(Font, MailInlineStyle)] = [
        (.body.bold().italic(), [.bold, .italic]),
        (.body.italic().bold(), [.bold, .italic]),
        (.body.bold(), .bold),
        (.body.italic(), .italic),
        (.body, []),
    ]

    /// The one font each style combination is stored as, so that two runs which
    /// look identical are identical and do not split.
    static func font(for style: MailInlineStyle) -> Font {
        switch (style.contains(.bold), style.contains(.italic)) {
        case (true, true): .body.bold().italic()
        case (true, false): .body.bold()
        case (false, true): .body.italic()
        case (false, false): .body
        }
    }

    /// Derives ``MailInlineStyle`` from what is actually on screen, then writes
    /// the canonical form of both back.
    ///
    /// A font this does not recognise — the residue of a paste the scope did
    /// not fully strip, or a future system that formats some other way —
    /// becomes plain. That is a real loss of formatting, but it is the only
    /// option that never lies: the run is reset to plain in the editor too, so
    /// what the sender sees is what will be sent.
    static func normalized(_ text: AttributedString) -> AttributedString {
        var output = text

        for run in text.runs {
            var style = MailInlineStyle()

            if let font = run.font, let match = recognised.first(where: { $0.0 == font }) {
                style.formUnion(match.1)
            }

            if run.underlineStyle != nil { style.insert(.underline) }
            if run.strikethroughStyle != nil { style.insert(.strikethrough) }

            output[run.range].inlineStyle = style.isEmpty ? nil : style
            output[run.range].font = font(for: style)
        }

        return output
    }

    // MARK: - Applying

    /// Toggles a style over the selection.
    ///
    /// Toggling writes the *visual* attributes; ``normalized(_:)`` then derives
    /// the style from them, which keeps this button and ⌘B on exactly the same
    /// path.
    static func toggle(
        _ style: MailInlineStyle,
        in text: inout AttributedString,
        selection: inout AttributedTextSelection
    ) {
        let isOn = active(in: text, selection: selection).contains(style)

        text.transformAttributes(in: &selection) { container in
            var current = MailInlineStyle()

            if let font = container.font, let match = recognised.first(where: { $0.0 == font }) {
                current.formUnion(match.1)
            }

            if container.underlineStyle != nil { current.insert(.underline) }
            if container.strikethroughStyle != nil { current.insert(.strikethrough) }

            if isOn { current.subtract(style) } else { current.formUnion(style) }

            container.font = font(for: current)
            container.underlineStyle = current.contains(.underline) ? .single : nil
            container.strikethroughStyle = current.contains(.strikethrough) ? .single : nil
            container.inlineStyle = current.isEmpty ? nil : current
        }
    }

    /// The styles covering the whole selection, for the toolbar's on/off state.
    ///
    /// Intersection rather than union: a selection that is half bold should
    /// show Bold as off, so pressing it makes all of it bold — which is what
    /// every editor does and what people expect.
    static func active(
        in text: AttributedString, selection: AttributedTextSelection
    ) -> MailInlineStyle {
        let indices = selection.indices(in: text)

        switch indices {
        case .insertionPoint(let index):
            // Formatting at a caret is the formatting of what precedes it —
            // that is what the next character will inherit.
            guard index > text.startIndex else { return [] }

            return text[text.characters.index(before: index)..<index].runs.first?.inlineStyle ?? []

        case .ranges(let ranges):
            var shared: MailInlineStyle?

            for range in ranges.ranges {
                for run in text[range].runs {
                    let style = run.inlineStyle ?? []
                    shared = shared.map { $0.intersection(style) } ?? style
                }
            }

            return shared ?? []
        }
    }

    /// Whether anything is selected, which is what a link can be attached to.
    static func hasSelection(
        in text: AttributedString, selection: AttributedTextSelection
    ) -> Bool {
        if case .ranges(let ranges) = selection.indices(in: text) {
            return ranges.ranges.contains { $0.isEmpty == false }
        }

        return false
    }

    static func setLink(
        _ url: URL?,
        in text: inout AttributedString,
        selection: inout AttributedTextSelection
    ) {
        text.transformAttributes(in: &selection) { container in
            container.link = url
        }
    }
}

#endif
