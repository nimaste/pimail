#if os(iOS)

import SwiftUI

/// The plMail mark: seven strokes in a single sweep from violet to rose.
///
/// **Drawn, not shipped as an image.** The mark is seven line segments and
/// three quarter-turns on a 48-point grid, so a vector here is smaller than a
/// PDF of the same thing, scales to a 1024pt icon without an asset, and can be
/// tinted where a flat asset could not. The geometry is the design's own — the
/// same seven strokes the web UI draws — rather than an approximation of it.
///
/// The strokes are **not** theme tokens and must not become them. Every other
/// colour in this app answers to the user's chosen accent; this one is the
/// product's identity, and an identity that changed when somebody picked Teal
/// would not be one.
struct PLMark: View {
    /// The mark's own colours, leading stroke first.
    private static let strokes: [Color] = [
        Color(red: 0.427, green: 0.157, blue: 0.851),  // #6d28d9
        Color(red: 0.486, green: 0.227, blue: 0.929),  // #7c3aed
        Color(red: 0.635, green: 0.110, blue: 0.686),  // #a21caf
        Color(red: 0.753, green: 0.149, blue: 0.827),  // #c026d3
        Color(red: 0.859, green: 0.153, blue: 0.467),  // #db2777
        Color(red: 0.882, green: 0.114, blue: 0.302),  // #e11d48
        Color(red: 0.957, green: 0.247, blue: 0.369),  // #f43f5e
    ]

    /// One stroke of the mark, in the 48-unit space the design draws it in.
    ///
    /// A `Shape` per stroke rather than one path in seven colours, because a
    /// gradient along a path cannot round its own caps and the design's are
    /// round at every join.
    private struct Stroke: Shape {
        let index: Int

        func path(in rect: CGRect) -> Path {
            let scale = min(rect.width, rect.height) / 48
            // The design's own `translate(-4.5 -0.5)`, kept rather than baked
            // into the coordinates so the numbers below can be read straight
            // off the source.
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: (x - 4.5) * scale + rect.minX, y: (y - 0.5) * scale + rect.minY)
            }

            var path = Path()

            switch index {
            case 0:
                path.move(to: p(13, 11))
                path.addLine(to: p(13, 42))
            case 1:
                path.move(to: p(13, 11))
                path.addQuadCurve(to: p(17, 7), control: p(13, 7))
                path.addLine(to: p(23, 7))
                path.addQuadCurve(to: p(29, 13), control: p(29, 7))
            case 2:
                path.move(to: p(29, 13))
                path.addLine(to: p(29, 22))
            case 3:
                path.move(to: p(29, 22))
                path.addQuadCurve(to: p(23, 26), control: p(29, 26))
                path.addLine(to: p(17, 26))
                path.addQuadCurve(to: p(13, 22), control: p(13, 26))
            case 4:
                path.move(to: p(37, 7))
                path.addLine(to: p(37, 26))
            case 5:
                path.move(to: p(37, 26))
                path.addLine(to: p(37, 37))
            default:
                path.move(to: p(37, 37))
                path.addQuadCurve(to: p(42, 42), control: p(37, 42))
                path.addLine(to: p(44, 42))
            }

            return path
        }
    }

    /// The point size the mark is drawn at. The stroke scales with it, so the
    /// weight stays the design's 5.5-in-48 at every size.
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            ForEach(Array(Self.strokes.enumerated()), id: \.offset) { index, colour in
                Stroke(index: index)
                    .stroke(
                        colour,
                        style: StrokeStyle(
                            lineWidth: 5.5 * size / 48, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(width: size, height: size)
        // One image to a reader, named once. Seven strokes announced one at a
        // time is seven pieces of nothing.
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: "plMail"))
        .accessibilityAddTraits(.isImage)
    }
}

#endif
