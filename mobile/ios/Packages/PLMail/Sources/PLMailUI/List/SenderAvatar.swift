#if os(iOS)

import SwiftUI

/// The correspondent, as a circle.
///
/// Carries no information a screen reader needs — the row already spells out
/// who the message is from — so it is hidden from accessibility rather than
/// labelled. Its job is to make a scrolling list scannable by shape and colour
/// before any word is read.
struct SenderAvatar: View {
    let name: String?
    let address: String?
    var diameter: CGFloat = 40

    /// Replaces the initials with a checkmark while the row is selected.
    ///
    /// The avatar doubles as the selection control because it is already the
    /// leading element of every row and already circular — Gmail does the same,
    /// and it means multi-select costs no extra column and no mode switch that
    /// reflows the list.
    var isSelected = false

    /// The checkmark's own curve, already reconciled with Reduce Motion.
    ///
    /// Read from the environment rather than written as a literal because a
    /// multi-select sweep animates one of these per row: somebody who set
    /// Reduce Motion because movement makes them ill got the whole list
    /// pulsing at them, which is precisely the case the setting exists for.
    @Environment(\.fastAnimation) private var fastAnimation

    var body: some View {
        Circle()
            // `AnyShapeStyle` because the two branches are different types —
            // the accent is resolved from the environment and the avatar hue
            // is a plain colour, and a ternary has nowhere to land without it.
            .fill(
                isSelected
                    ? AnyShapeStyle(ThemeAccent())
                    : AnyShapeStyle(AvatarPalette.color(for: seed))
            )
            .frame(width: diameter, height: diameter)
            .overlay {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: diameter * 0.42, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text(initials)
                        .font(.system(size: diameter * 0.4, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .minimumScaleFactor(0.6)
                }
            }
            .animation(fastAnimation, value: isSelected)
            .accessibilityHidden(true)
    }

    /// The address when there is one: a display name changes between messages
    /// from the same person, and the colour must not change with it.
    private var seed: String {
        let address = address ?? ""

        return address.isEmpty ? (name ?? "?") : address
    }

    private var initials: String {
        let initials = AvatarPalette.initials(name: name, address: address)

        return initials.isEmpty ? "?" : initials
    }
}

#endif
