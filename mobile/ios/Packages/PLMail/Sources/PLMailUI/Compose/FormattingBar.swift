#if os(iOS)

public import PLMailCore

import SwiftUI

/// Bold, italic, underline, strikethrough and links, above the keyboard.
///
/// On the keyboard's own toolbar rather than in the navigation bar: formatting
/// is something you reach for mid-sentence, and a control at the top of the
/// screen means moving your thumb the length of the phone and losing your place
/// in the text.
struct FormattingBar: View {
    @Binding var text: AttributedString
    @Binding var selection: AttributedTextSelection

    @State private var isAddingLink = false
    @State private var linkText = ""

    private var active: MailInlineStyle {
        RichTextEditor.active(in: text, selection: selection)
    }

    var body: some View {
        HStack(spacing: 4) {
            button(.bold, systemImage: "bold", label: .ui("Bold"))
            button(.italic, systemImage: "italic", label: .ui("Italic"))
            button(.underline, systemImage: "underline", label: .ui("Underline"))
            button(.strikethrough, systemImage: "strikethrough", label: .ui("Strikethrough"))

            Divider().frame(height: 20)

            Button(.ui("Add link"), systemImage: "link") {
                linkText = ""
                isAddingLink = true
            }
            .labelStyle(.iconOnly)
            .disabled(RichTextEditor.hasSelection(in: text, selection: selection) == false)

            Spacer(minLength: 0)
        }
        .buttonStyle(.plain)
        .font(.body)
        .alert(Text(.ui("Add link")), isPresented: $isAddingLink) {
            TextField("https://", text: $linkText)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            Button(.ui("Cancel"), role: .cancel) {}
            Button(.ui("Add")) { addLink() }
        } message: {
            Text(.ui("The selected text will link here."))
        }
    }

    private func button(
        _ style: MailInlineStyle, systemImage: String, label: LocalizedStringResource
    ) -> some View {
        let isOn = active.contains(style)

        return Button {
            RichTextEditor.toggle(style, in: &text, selection: &selection)
        } label: {
            Image(systemName: systemImage)
                .frame(width: 32, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        // Erased rather than left as a ternary of colours. The
                        // accent is a `ShapeStyle` that resolves itself from the
                        // environment, so its branch and `.clear` are different
                        // types and the ternary has nowhere to land — the same
                        // reason ``ThemeAccent`` is a style rather than a
                        // `Color` in the first place.
                        .fill(
                            isOn
                                ? AnyShapeStyle(ThemeAccent().opacity(0.18))
                                : AnyShapeStyle(.clear))
                )
                .foregroundStyle(isOn ? AnyShapeStyle(.themeAccent) : AnyShapeStyle(.primary))
        }
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    /// Bare hostnames are what people type. Without this, "example.com"
    /// becomes a relative link that resolves against nothing.
    private func addLink() {
        let trimmed = linkText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmed.isEmpty == false else { return }

        let normalized = trimmed.contains("://") ? trimmed : "https://\(trimmed)"

        guard let url = URL(string: normalized) else { return }

        RichTextEditor.setLink(url, in: &text, selection: &selection)
    }
}

#endif
