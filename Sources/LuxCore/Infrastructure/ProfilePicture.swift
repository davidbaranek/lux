import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Makes a picked image the account's picture, off the main thread, with ImageIO: upright, cut to
/// its centre square, at most `side` pixels, as a JPEG. Other apps show it small and round.
public enum ProfilePicture {
    public static let side = 512

    public enum Failure: LocalizedError {
        case unreadable

        public var errorDescription: String? { String(localized: "This picture could not be read.") }
    }

    /// The JPEG of `data` (any image ImageIO reads: HEIC, JPEG, PNG…).
    @concurrent
    public static func jpeg(from data: Data) async throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { throw Failure.unreadable }
        // decoded small enough that its shorter side still covers the square.
        let longest = max(width, height) * side / min(width, height)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(longest, max(width, height)),
        ]
        guard let upright = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw Failure.unreadable }
        let square = min(upright.width, upright.height)
        let crop = CGRect(x: (upright.width - square) / 2, y: (upright.height - square) / 2, width: square, height: square)
        guard let cut = upright.cropping(to: crop) else { throw Failure.unreadable }
        let out = min(square, side)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: out, height: out, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw Failure.unreadable }
        context.interpolationQuality = .high
        context.draw(cut, in: CGRect(x: 0, y: 0, width: out, height: out))
        guard let image = context.makeImage() else { throw Failure.unreadable }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw Failure.unreadable
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.unreadable }
        return encoded as Data
    }
}
