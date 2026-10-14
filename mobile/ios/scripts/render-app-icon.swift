import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// The mark's seven strokes, in the design's 48-unit space (already carrying
// its translate(-4.5 -0.5)), each with its own colour.
struct Seg { let ops: [(CGPoint, CGPoint?)]; let start: CGPoint; let rgb: (CGFloat, CGFloat, CGFloat) }

func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x - 4.5, y: y - 0.5) }

let segments: [Seg] = [
    Seg(ops: [(p(13, 42), nil)], start: p(13, 11), rgb: (0.427, 0.157, 0.851)),
    Seg(ops: [(p(17, 7), p(13, 7)), (p(23, 7), nil), (p(29, 13), p(29, 7))],
        start: p(13, 11), rgb: (0.486, 0.227, 0.929)),
    Seg(ops: [(p(29, 22), nil)], start: p(29, 13), rgb: (0.635, 0.110, 0.686)),
    Seg(ops: [(p(23, 26), p(29, 26)), (p(17, 26), nil), (p(13, 22), p(13, 26))],
        start: p(29, 22), rgb: (0.753, 0.149, 0.827)),
    Seg(ops: [(p(37, 26), nil)], start: p(37, 7), rgb: (0.859, 0.153, 0.467)),
    Seg(ops: [(p(37, 37), nil)], start: p(37, 26), rgb: (0.882, 0.114, 0.302)),
    Seg(ops: [(p(42, 42), p(37, 42)), (p(44, 42), nil)], start: p(37, 37), rgb: (0.957, 0.247, 0.369)),
]

let side = 1024
let space = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
    space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
else { fatalError("no context") }

// Paper, the theme's own surface. An icon on white would be the one plMail
// surface that is not the user's paper.
ctx.setFillColor(red: 0.969, green: 0.961, blue: 0.937, alpha: 1)
ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))

// The glyph's true inked bounds, stroke included: x 13-2.75 … 44+2.75 and
// y 7-2.75 … 42+2.75 in the pre-translate space. Centring on the 48-unit
// viewBox instead would centre the *canvas*, and the mark does not fill it.
let inkMinX: CGFloat = 13 - 2.75 - 4.5
let inkMaxX: CGFloat = 44 + 2.75 - 4.5
let inkMinY: CGFloat = 7 - 2.75 - 0.5
let inkMaxY: CGFloat = 42 + 2.75 - 0.5
let inkWidth = inkMaxX - inkMinX
let inkHeight = inkMaxY - inkMinY

// 62% of the tile on its longer side — iOS rounds the corners of this and
// crops a circle out of it elsewhere, so the glyph stays well inside.
let markSide = CGFloat(side) * 0.62
let scale = markSide / max(inkWidth, inkHeight)
let originX = (CGFloat(side) - inkWidth * scale) / 2 - inkMinX * scale
let originY = (CGFloat(side) - inkHeight * scale) / 2 - inkMinY * scale

// CoreGraphics has y upwards; the design's space has it downwards.
func t(_ q: CGPoint) -> CGPoint {
    CGPoint(x: originX + q.x * scale, y: CGFloat(side) - (originY + q.y * scale))
}

ctx.setLineWidth(5.5 * scale)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)

for segment in segments {
    ctx.setStrokeColor(red: segment.rgb.0, green: segment.rgb.1, blue: segment.rgb.2, alpha: 1)
    ctx.beginPath()
    ctx.move(to: t(segment.start))

    for (end, control) in segment.ops {
        if let control {
            ctx.addQuadCurve(to: t(end), control: t(control))
        } else {
            ctx.addLine(to: t(end))
        }
    }

    ctx.strokePath()
}

guard let image = ctx.makeImage() else { fatalError("no image") }
let url = URL(fileURLWithPath: CommandLine.arguments[1])
guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
else { fatalError("no destination") }
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("wrote \(url.path)")
