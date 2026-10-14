import Foundation
import ImageIO
import OSLog
import UniformTypeIdentifiers

/// Takes the location out of a photo before it is attached.
///
/// A photo from the library carries EXIF, and EXIF usually carries GPS — the
/// picker says so in small print, and nobody reads it. Attaching a picture of a
/// broken boiler to a tradesman therefore also sends them the coordinates of
/// the house, to about five metres.
///
/// This app already blocks remote images because loading one tells a sender
/// when and roughly where a message was opened. Sending exact coordinates in
/// the other direction, silently, would be a strange line to draw.
///
/// Only location is removed. Orientation, colour profile and the rest are what
/// make the picture render correctly at the other end, and stripping metadata
/// wholesale is how photos arrive rotated.
public enum ImagePrivacy {
    private static let logger = Logger(subsystem: "de.plmail", category: "attachments")

    /// Returns the image without its GPS tags, or the original bytes if it has
    /// none, is not an image, or cannot be rewritten.
    ///
    /// Never fails outward. A photo somebody wanted to send is not worth losing
    /// over metadata, so the fallback is always "send what we were given".
    public static func strippingLocation(from data: Data, type: String) -> Data {
        guard type.hasPrefix("image/") else { return data }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let uti = CGImageSourceGetType(source)
        else { return data }

        let count = CGImageSourceGetCount(source)

        guard count > 0 else { return data }

        // Nothing to do is the common case — screenshots have no GPS — and
        // rewriting an image that needs no change risks recompression for no
        // benefit.
        guard hasLocation(source, count: count) else { return data }

        let output = NSMutableData()

        guard
            let destination = CGImageDestinationCreateWithData(
                output as CFMutableData, uti, count, nil)
        else { return data }

        for index in 0..<count {
            // `kCGImagePropertyGPSDictionary: kCFNull` is the documented way to
            // *remove* a property. Passing an empty dictionary leaves the
            // original in place, which looks identical in code and does
            // nothing.
            let removals: [CFString: Any] = [
                kCGImagePropertyGPSDictionary: kCFNull as Any
            ]

            CGImageDestinationAddImageFromSource(
                destination, source, index, removals as CFDictionary)
        }

        guard CGImageDestinationFinalize(destination) else {
            logger.error("Could not rewrite an image to remove its location; sending as-is.")

            return data
        }

        return output as Data
    }

    /// Whether any frame carries GPS tags.
    public static func hasLocation(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }

        return hasLocation(source, count: CGImageSourceGetCount(source))
    }

    private static func hasLocation(_ source: CGImageSource, count: Int) -> Bool {
        for index in 0..<count {
            let properties =
                CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]

            if properties?[kCGImagePropertyGPSDictionary] != nil { return true }
        }

        return false
    }
}
