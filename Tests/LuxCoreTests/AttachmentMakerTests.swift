import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import LuxCore

struct AttachmentMakerTests {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("attachment-tests-\(UUID().uuidString)")

    /// A plain picture of `width` × `height` pixels, stored with an EXIF orientation.
    private func picture(width: Int, height: Int, orientation: Int, type: UTType, name: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let file = folder.appendingPathComponent(name)
        let destination = CGImageDestinationCreateWithURL(file as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return file
    }

    @Test func aTurnedPhotoGoesUprightAsAJPEGWithAThumbnail() async throws {
        // stored 1600 × 1200, shown turned a quarter (orientation 6): upright it is 1200 × 1600.
        let source = try picture(width: 1600, height: 1200, orientation: 6, type: .heic, name: "IMG_1.heic")
        let attachment = try await AttachmentMaker.prepare(source, in: folder)
        #expect(attachment.name == "IMG_1.jpg")
        #expect(attachment.mimetype == "image/jpeg")
        #expect(attachment.kind == .photo(width: 1200, height: 1600))
        #expect(attachment.thumbnail.map { max($0.width, $0.height) } == 800)
    }

    @Test func aPNGKeepsItsFileAndAnythingElseGoesAsAFile() async throws {
        let png = try await AttachmentMaker.prepare(try picture(width: 300, height: 200, orientation: 1, type: .png, name: "shot.png"), in: folder)
        #expect(png.name == "shot.png" && png.mimetype == "image/png" && png.kind == .photo(width: 300, height: 200))
        let text = folder.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: text)
        let file = try await AttachmentMaker.prepare(text, in: folder)
        #expect(file.kind == .file && file.mimetype == "text/plain" && file.size == 5)
    }
}
