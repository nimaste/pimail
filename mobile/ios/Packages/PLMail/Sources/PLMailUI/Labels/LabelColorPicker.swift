#if os(iOS)

import JMAPKit
import SwiftUI

/// Choosing one of the nine colours, or none.
///
/// A closed vocabulary drawn as swatches rather than a `ColorPicker`: plMail
/// stores a Tailwind token, and the system picker would offer a hex value the
/// server refuses with `invalidProperties` — an error arriving after the user
/// has already chosen, about a colour they can see on screen.
///
/// **Every swatch says its name.** A grid of nine hues with no words is a
/// control that cannot be used by anyone who cannot separate them, and nine
/// buttons all read out as "button" is the same problem in the other channel.
/// The tick, not the hue, is what marks the selection.
extension LabelTint {
    /// The colour's name, for anything that has to say it out loud.
    ///
    /// Here rather than beside the hues in `LabelTint` because `.ui(…)` lives
    /// inside this module's iOS fence and the tint resolution deliberately does
    /// not — the palette is testable on the macOS host, the words are not.
    ///
    /// A swatch grid with no names is unusable by anyone who cannot tell the
    /// two greens apart — colour-blind, low vision, or reading the screen
    /// through VoiceOver — and "button" nine times is not a choice.
    static func name(for color: LabelColor) -> LocalizedStringResource {
        switch color {
        case .gray: .ui("Grey")
        case .red: .ui("Red")
        case .orange: .ui("Orange")
        case .amber: .ui("Amber")
        case .green: .ui("Green")
        case .teal: .ui("Teal")
        case .blue: .ui("Blue")
        case .violet: .ui("Violet")
        case .pink: .ui("Pink")
        }
    }

    /// What to call the absence of a colour.
    ///
    /// Deliberately not "Grey" and not "Default": the first is a colour the
    /// user can actually pick and the second says nothing about what will be
    /// drawn. "No colour" is the state, and the swatch beside it shows the
    /// fallback tint so the words and the circle agree.
    static var noColorName: LocalizedStringResource { .ui("No colour") }
}

struct LabelColorPicker: View {
    @Binding var selection: LabelColor?
    /// Seeds the fallback tint on the "No colour" swatch, so that swatch shows
    /// what the label will actually look like rather than a grey circle — which
    /// would make "no colour" and "grey" the same choice on screen when they
    /// are two different things on the wire.
    let fallbackSeed: String

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // Restacked at accessibility sizes: a row of swatches with their names
        // beside them cannot shrink, and a horizontally scrolling control the
        // user cannot see the end of is worse than a taller list.
        if dynamicTypeSize.isAccessibilitySize {
            ForEach(options, id: \.self) { option in
                swatchRow(option)
            }
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), alignment: .leading)]) {
                ForEach(options, id: \.self) { option in
                    swatchRow(option)
                }
            }
        }
    }

    /// Nil first: it is the state a new label starts in, and putting it at the
    /// end would read as an afterthought rather than as the default.
    private var options: [LabelColor?] {
        [nil] + LabelColor.allCases
    }

    private func swatchRow(_ option: LabelColor?) -> some View {
        let isSelected = option == selection
        let title = option.map(LabelTint.name(for:)) ?? LabelTint.noColorName

        return Button {
            selection = option
        } label: {
            HStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(LabelTint.color(for: option, seed: fallbackSeed))
                        .frame(width: 20, height: 20)

                    // The tick carries the selection, not a ring in a colour
                    // that has to be told apart from eight others.
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                    }
                }

                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

#endif
