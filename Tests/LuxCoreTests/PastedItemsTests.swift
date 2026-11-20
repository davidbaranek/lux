import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import LuxCore

/// What a paste or a drop brings the composer: which items are files, pictures or videos to attach
/// and which are text, and the files they become.
@Suite(.ownFolder) struct PastedItemsTests {
    private let folder: URL

    init() throws {
        folder = try TemporaryFolder.ofTest
    }

    private func type(of types: [UTType]) -> UTType? {
        PastedItems.attachableType(of: types.map(\.identifier))
    }

    @Test func aFileCopiedInFinderIsTheFileNotItsNameOrIcon() {
        #expect(type(of: [.fileURL, .utf8PlainText, .tiff]) == .fileURL)
    }

    @Test func aPictureIsItsRichestImageWithTIFFLast() {
        // a screenshot copied on the Mac: a TIFF beside the PNG.
        #expect(type(of: [.tiff, .png]) == .png)
        #expect(type(of: [.tiff]) == .tiff)
        #expect(type(of: [.heic, .jpeg]) == .heic)
        #expect(type(of: [.mpeg4Movie]) == .mpeg4Movie)
        #expect(type(of: [.pdf]) == .pdf)
    }

    @Test func textIsLeftToTheTextViewEvenWithAPictureInIt() {
        #expect(type(of: [.utf8PlainText]) == nil)
        #expect(type(of: [.flatRTFD, .rtf, .utf8PlainText, .png]) == nil)
        #expect(type(of: [.html, .utf8PlainText]) == nil)
        // a copied link.
        #expect(type(of: [.url, .utf8PlainText]) == nil)
        #expect(type(of: [.url]) == nil)
        // an app's own type, which no other app reads.
        #expect(PastedItems.attachableType(of: ["dyn.ah62d4rv4gu8yc6durvwwaznwmuuha2pxsvw0e55bsmwca7d3sbwu"]) == nil)
    }

    @Test func pastedBytesBecomeAFileNamedForWhatTheyAre() async throws {
        let bytes = Data("picture".utf8)
        let files = try await PastedItems.files([
            .data(bytes, type: .png, name: nil),
            .data(bytes, type: .png, name: nil),
            .data(bytes, type: .png, name: "Screenshot"),
            .data(bytes, type: .jpeg, name: "holiday.jpeg"),
            .data(bytes, type: .mpeg4Movie, name: nil),
            .data(bytes, type: .pdf, name: nil),
        ], in: folder)
        #expect(files.map(\.lastPathComponent)
            == ["Pasted Image.png", "Pasted Image.png", "Screenshot.png", "holiday.jpeg", "Pasted Video.mp4", "Pasted File.pdf"])
        // two pastes of one name keep it, each in a folder of its own.
        #expect(files[0] != files[1])
        #expect(try Data(contentsOf: files[0]) == bytes)
    }

    @Test func aPastedFileIsAttachedWhereItIs() async throws {
        let file = folder.appendingPathComponent("Trip plan.pdf")
        try Data("plan".utf8).write(to: file)
        #expect(try await PastedItems.files([.file(file)], in: folder) == [file])
    }

    @Test func aPastedPictureIsMadeReadyAsAPickedOneIs() async throws {
        let picture = folder.appendingPathComponent("source.png")
        try picturePNG(width: 300, height: 200, to: picture)
        let pasted = try await PastedItems.files([.data(try Data(contentsOf: picture), type: .png, name: nil)], in: folder)
        let attachment = try await AttachmentMaker.prepare(try #require(pasted.first), in: folder)
        #expect(attachment.name == "Pasted Image.png" && attachment.mimetype == "image/png")
        #expect(attachment.kind == .photo(width: 300, height: 200))
    }

    @Test @MainActor func aProvidersFileIsCopiedUnderTheNameItSuggests() async throws {
        let bytes = Data("screenshot".utf8)
        let provider = NSItemProvider()
        provider.registerDataRepresentation(for: .png) { load in
            load(bytes, nil)
            return nil
        }
        provider.suggestedName = "Screenshot"
        let type = try #require(PastedItems.attachableType(of: provider.registeredTypeIdentifiers))
        let file = try await PastedItems.copying(from: provider, type: type, name: provider.suggestedName, in: folder).value
        #expect(file.lastPathComponent == "Screenshot.png")
        #expect(try Data(contentsOf: file) == bytes)
    }

    /// A plain PNG of `width` × `height` pixels.
    private func picturePNG(width: Int, height: Int, to file: URL) throws {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}
