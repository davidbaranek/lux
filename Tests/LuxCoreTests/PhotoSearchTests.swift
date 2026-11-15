import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import LuxCore

/// The folder of photo search's model (`scripts/image-search/package.sh` writes it as
/// `<out>/PhotoSearch`): the tests that need the model run only with it, as
/// `LUX_PHOTO_MODEL=<folder> swift test`.
private let modelFolder = ProcessInfo.processInfo.environment["LUX_PHOTO_MODEL"].map { URL(fileURLWithPath: $0) }

private func folder() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "lux-photos-\(UUID().uuidString)", directoryHint: .isDirectory)
}

/// A picture of a receipt: lines of black text on white, as a PNG file.
private func receipt(_ lines: [String]) throws -> URL {
    let size = CGSize(width: 900, height: 120 + 90 * lines.count)
    let context = try #require(CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                         bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(origin: .zero, size: size))
    let font = CTFontCreateWithName("Helvetica" as CFString, 48, nil)
    for (index, line) in lines.enumerated() {
        let text = NSAttributedString(string: line, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ])
        context.textPosition = CGPoint(x: 60, y: size.height - 120 - CGFloat(index) * 90)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
    }
    let file = folder().appending(path: "receipt.png")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let destination = try #require(CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
    #expect(CGImageDestinationFinalize(destination))
    return file
}

@Suite struct PhotoReaderTests {
    @Test func readsTheWordsInAPhotoWithoutTheModel() async throws {
        let reader = PhotoReader(model: nil)
        let read = try await reader.read(try receipt(["Faktura 2024-118", "Celkem 1 250 Kč"]))
        #expect(read.words.contains("Faktura"))
        #expect(read.words.contains("Celkem"))
        #expect(read.embedding == nil)
        #expect(reader.name == "vision-text-1")
    }

    @Test(.enabled(if: modelFolder != nil, "needs the model: LUX_PHOTO_MODEL"))
    func findsAPhotoByHowItLooks() async throws {
        let model = try PhotoSearchModel(folder: try #require(modelFolder))
        await model.textEncoderLoaded()
        let pictures = URL(fileURLWithPath: "/System/Library/Desktop Pictures/.thumbnails")
        var looks: [String: [Float]] = [:]
        for name in ["Big Sur Coastline", "The Desert", "Big Sur Night Succulents"] {
            let read = try await PhotoReader(model: model).read(pictures.appending(path: "\(name).heic"))
            let embedding = try #require(read.embedding)
            looks[name] = embedding
        }
        func best(_ words: String) async throws -> String? {
            let embedding = try #require(try await model.embedding(of: words))
            return looks.max { zip($0.value, embedding).map(*).reduce(0, +) < zip($1.value, embedding).map(*).reduce(0, +) }?.key
        }
        #expect(try await best("waves on a rocky coast") == "Big Sur Coastline")
        #expect(try await best("sand dunes in the desert") == "The Desert")
        #expect(try await best("kaktusy v noci") == "Big Sur Night Succulents")
    }
}

@Suite struct PhotoIndexerTests {
    @Test func readsEveryPhotoOfTheDemoOnce() async throws {
        let store = try await LocalStore.open(file: folder().appending(path: "index.sqlite"), key: String(repeating: "ef", count: 32))
        let account = Task<RustAccount, any Error> { RustAccount.demo(rooms: 20, messagesPerRoom: 60) }
        let (reports, report) = AsyncStream<SearchIndexer.Progress>.makeStream()
        let texts = SearchIndexer(store: store, account: account, maxChats: 2) { report.yield($0) }
        await texts.update()
        for await progress in reports where !progress.isIndexing { break }
        let kept = try await store.imageCounts(reader: PhotoReader(model: nil).name)
        #expect(kept.total > 0 && kept.read == 0)

        let photos = PhotoIndexer(store: store, account: account, directory: folder(), model: nil) { _ in }
        #expect(await photos.read(limit: nil))
        #expect(try await store.imageCounts(reader: PhotoReader(model: nil).name).read == kept.total)
        // nothing is left to read, and the downloads are gone.
        #expect(try await store.imagesToRead(by: PhotoReader(model: nil).name, limit: 10).isEmpty)
    }
}
