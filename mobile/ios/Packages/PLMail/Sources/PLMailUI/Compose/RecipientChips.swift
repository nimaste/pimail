#if os(iOS)

import PLMailCore
import SwiftUI

/// One committed recipient, as a chip.
///
/// The field itself is still one comma-separated string — that is what the
/// model saves, what the draft carries and what `RecipientParsing` reads — and
/// this draws the part of it that has already been typed past. Nothing here
/// owns any state: a chip is a view of a substring, and removing one rewrites
/// the string it came from.
///
/// An entry that is **not** an address keeps its raw text and takes the danger
/// ink, which is the same fact the footer states in a sentence. A chip that
/// looked identical either way would be a control that hides the one thing it
/// is in a position to show.
struct RecipientChip: View {
    let token: String
    let onRemove: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = theme.palette(for: colorScheme)
        let address = RecipientParsing.parse(token)

        HStack(spacing: 6) {
            // The same circle the list and the reader draw, so a recipient
            // looks like the person they will be in the thread that follows.
            SenderAvatar(name: address?.name, address: address?.email, diameter: 22)

            Text(address?.displayName ?? token)
                .font(.subheadline)
                .foregroundStyle(address == nil ? palette.danger.color : palette.ink.color)
                .lineLimit(1)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(palette.inkMuted.color)
                    .frame(width: 24, height: 24)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(.ui("Remove recipient")))
        }
        .padding(.leading, 3)
        .padding(.vertical, 3)
        .background(palette.sunken.color, in: .capsule)
        // Contained rather than combined: the chip is a name *and* a control,
        // and combining them would leave the remove button unreachable.
        .accessibilityElement(children: .contain)
    }
}

/// Chips, wrapped onto as many lines as they need.
///
/// SwiftUI has no flow container, and the two usual substitutes are both wrong
/// here: a horizontal `ScrollView` hides recipients behind a gesture — the one
/// list where "who else is this going to" must be answerable at a glance — and
/// an `HStack` squeezes them until every name truncates to two characters.
struct ChipFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout Void
    ) -> CGSize {
        let width = proposal.width ?? .infinity
        let laid = arrange(subviews, within: width)

        return CGSize(width: proposal.width ?? laid.width, height: laid.height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void
    ) {
        let laid = arrange(subviews, within: bounds.width)

        for (index, subview) in subviews.enumerated() {
            let frame = laid.frames[index]

            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size))
        }
    }

    /// Where each chip lands, and how much room that took.
    ///
    /// Run twice — once to measure, once to place — rather than cached: the
    /// count here is the number of recipients on one message, and a cache that
    /// went stale would put a chip somewhere its tap target is not.
    private func arrange(
        _ subviews: Subviews, within width: CGFloat
    ) -> (frames: [CGRect], width: CGFloat, height: CGFloat) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            // Never break before the first chip on a line: one wider than the
            // whole field has nowhere better to go, and wrapping it would
            // leave an empty line above it.
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }

            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }

        return (frames, widest, y + lineHeight)
    }
}

#endif
