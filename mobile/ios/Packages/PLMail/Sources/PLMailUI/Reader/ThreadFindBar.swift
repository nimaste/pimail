#if os(iOS)

import PLMailCore
import SwiftUI

/// Find within the open conversation.
///
/// Sits under the navigation bar rather than over the reply bar, because it is
/// a filter on what you are reading and not an action on it — and because the
/// keyboard comes up from the bottom, which is where the reply bar already is.
struct ThreadFindBar: View {
    @Bindable var model: ThreadFindModel
    let onClose: () -> Void

    @FocusState private var isFocused: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                TextField(.ui("Find in conversation"), text: $model.query)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.next)
                    .focused($isFocused)
                    .onSubmit { model.next() }

                if model.hasQuery {
                    Text(model.statusText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(model.matches.isEmpty ? .orange : .secondary)
                        // The count is the reason the bar exists, so it never
                        // gives up its width to the query someone can already
                        // see themselves typing.
                        .layoutPriority(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.quaternary.opacity(0.5), in: Capsule())

            // Stacked rather than side by side once the words get large: two
            // chevrons and a Done at accessibility sizes do not fit a phone's
            // width, and the row would hyphenate "Done".
            step(systemImage: "chevron.up", label: .ui("Previous match"), action: model.previous)
            step(systemImage: "chevron.down", label: .ui("Next match"), action: model.next)

            Button(.ui("Done"), action: onClose)
                .font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PanelStyle.hairline)
                .frame(height: 1)
        }
        .onAppear { isFocused = true }
    }

    private func step(
        systemImage: String, label: LocalizedStringResource, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.footnote.weight(.semibold))
                .frame(width: 30, height: 30)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(model.matches.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
        .disabled(model.matches.isEmpty)
        .accessibilityLabel(Text(label))
    }
}

/// Draws a string with its find matches picked out.
///
/// For the text SwiftUI renders itself — a sender's name, a recipient list, a
/// plain-text body. The HTML bodies are highlighted in the DOM instead, which
/// is a different mechanism for the same idea; see ``PLMailCore/ThreadFind``.
struct FoundText: View {
    let text: String
    let ranges: [Range<String.Index>]
    /// Which of them is the current match, if it is in this string at all.
    let currentOccurrence: Int?

    var body: some View {
        Text(attributed)
    }

    private var attributed: AttributedString {
        var result = AttributedString(text)

        for (occurrence, range) in ranges.enumerated() {
            guard let scoped = Range(range, in: result) else { continue }

            let isCurrent = occurrence == currentOccurrence

            // The same two weights of one hue the message bodies use, so a
            // match in a header and a match in a body are recognisably the
            // same thing found twice.
            result[scoped].backgroundColor = isCurrent ? .findCurrent : .find
            result[scoped].foregroundColor = isCurrent ? .findCurrentInk : .findInk
        }

        return result
    }
}

extension Color {
    /// Amber, the palette's warm hue — the one ``ActionTint/star`` is drawn
    /// from. Stated for both appearances because a highlight that works on
    /// cream paper is invisible on near-black.
    fileprivate static let find = Color(
        light: Color(red: 0.973, green: 0.839, blue: 0.478),
        dark: Color(red: 0.478, green: 0.361, blue: 0.110)
    )
    fileprivate static let findInk = Color(
        light: Color(red: 0.110, green: 0.110, blue: 0.118),
        dark: Color(red: 0.961, green: 0.961, blue: 0.969)
    )
    fileprivate static let findCurrent = Color(
        light: Color(red: 0.878, green: 0.627, blue: 0.125),
        dark: Color(red: 0.851, green: 0.663, blue: 0.227)
    )
    fileprivate static let findCurrentInk = Color(
        light: Color(red: 0.110, green: 0.110, blue: 0.118),
        dark: Color(red: 0.110, green: 0.110, blue: 0.118)
    )
}

#endif
