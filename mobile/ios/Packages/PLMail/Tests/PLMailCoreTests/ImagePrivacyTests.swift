import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import PLMailCore

/// Stripping GPS from a photo before it is attached.
///
/// Built as a real JPEG with real EXIF rather than a fixture, so the test is
/// exercising ImageIO's actual behaviour — including the part that is easy to
/// get wrong, where an empty dictionary silently leaves the tags in place.
@Suite("Image privacy")
struct ImagePrivacyTests {
    /// A 4×4 JPEG, optionally carrying coordinates.
    private func jpeg(withLocation: Bool) throws -> Data {
        let width = 4
        let height = 4
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))

        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(
                output as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil))

        var properties: [CFString: Any] = [:]

        if withLocation {
            properties[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: 51.5074,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 0.1278,
                kCGImagePropertyGPSLongitudeRef: "W",
            ]
        }

        CGImageDestinationAddImage(destination, image, properties as CFDictionary)

        #expect(CGImageDestinationFinalize(destination))

        return output as Data
    }

    @Test("A photo's coordinates are removed")
    func stripsLocation() throws {
        let original = try jpeg(withLocation: true)

        #expect(ImagePrivacy.hasLocation(original), "The fixture has no GPS to remove.")

        let cleaned = ImagePrivacy.strippingLocation(from: original, type: "image/jpeg")

        #expect(ImagePrivacy.hasLocation(cleaned) == false)
    }

    /// The picture still has to arrive. Stripping metadata by rewriting the
    /// file is the sort of thing that quietly produces a zero-byte attachment.
    @Test("The image survives having its location removed")
    func imageStillDecodes() throws {
        let cleaned = ImagePrivacy.strippingLocation(
            from: try jpeg(withLocation: true), type: "image/jpeg")

        let source = try #require(CGImageSourceCreateWithData(cleaned as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))

        #expect(image.width == 4)
        #expect(image.height == 4)
    }

    /// Most images have no GPS at all. Rewriting them would recompress for
    /// nothing, so they are expected back byte-identical.
    @Test("An image with no location is returned untouched")
    func untouchedWithoutLocation() throws {
        let original = try jpeg(withLocation: false)

        #expect(ImagePrivacy.strippingLocation(from: original, type: "image/jpeg") == original)
    }

    /// A PDF is not an image and must not go through ImageIO.
    @Test("Non-images pass straight through")
    func nonImage() {
        let data = Data("%PDF-1.4 not really".utf8)

        #expect(ImagePrivacy.strippingLocation(from: data, type: "application/pdf") == data)
    }

    /// Claiming to be an image and not being one is what a malformed upload
    /// looks like. It must come back unchanged rather than empty.
    @Test("Bytes that are not a decodable image are returned unchanged")
    func malformedImage() {
        let data = Data("this is not a jpeg".utf8)

        #expect(ImagePrivacy.strippingLocation(from: data, type: "image/jpeg") == data)
    }
}
