import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import Vision
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

/// Whether this machine reads text in a picture at all: Vision's text recognition needs the GPU or
/// the Neural Engine, which a virtual machine (GitHub's macOS runners) does not have, and fails
/// there with `unknownError`. The tests that read photos run where it can; their failure on such a
/// machine would say nothing about the app.
private let recognizesText = ConditionTrait.enabled("Vision reads no text on this machine (a VM without a GPU)") {
    await visionReadsText.value
}

/// Asked once for both suites: the first read compiles Vision's model, which takes long there.
/// As the app reads, on the executor for work that holds its thread, not Swift's pool.
private let visionReadsText = Task(executorPreference: ImageWork.executor) {
    let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
    guard let image = context?.makeImage() else { return false }
    do {
        _ = try PhotoReader.words(in: image)
        return true
    } catch {
        return false
    }
}

@Suite(recognizesText) struct PhotoReaderTests {
    @Test func readsTheWordsInAPhotoWithoutTheModel() async throws {
        let reader = PhotoReader(model: nil)
        let read = try await leased { [file = try receipt(["Faktura 2024-118", "Celkem 1 250 Kč"])] lease in
            try await reader.read(file, lease: lease)
        }
        #expect(read.words.contains("Faktura"))
        #expect(read.words.contains("Celkem"))
        #expect(read.embedding == nil)
        #expect(reader.name == "vision-text-1")
    }

    @Test(.enabled(if: modelFolder != nil, "needs the model: LUX_PHOTO_MODEL"))
    func findsAPhotoByHowItLooks() async throws {
        let model = try PhotoSearchModel(folder: try #require(modelFolder))
        try await leased { lease in await model.textEncoderLoaded(lease: lease) }
        let pictures = URL(fileURLWithPath: "/System/Library/Desktop Pictures/.thumbnails")
        var looks: [String: [Float]] = [:]
        for name in ["Big Sur Coastline", "The Desert", "Big Sur Night Succulents"] {
            let file = pictures.appending(path: "\(name).heic")
            let read = try await leased { lease in try await PhotoReader(model: model).read(file, lease: lease) }
            let embedding = try #require(read.embedding)
            looks[name] = embedding
        }
        func cosine(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).map(*).reduce(0, +) }
        func best(_ words: String) async throws -> String? {
            let embedding = try #require(try await model.embedding(ofQuery: words))
            let found = looks.max { cosine($0.value, embedding) < cosine($1.value, embedding) }
            // alike enough to be found by its look.
            #expect(cosine(try #require(found).value, embedding) >= model.minSimilarity)
            return found?.key
        }
        #expect(try await best("waves on a rocky coast") == "Big Sur Coastline")
        #expect(try await best("sand dunes in the desert") == "The Desert")
        #expect(try await best("kaktusy v noci") == "Big Sur Night Succulents")
    }

    @Test(.enabled(if: modelFolder != nil, "needs the model: LUX_PHOTO_MODEL"))
    func findsAMessageByWhatItMeans() async throws {
        let model = try PhotoSearchModel(folder: try #require(modelFolder))
        try await leased { lease in await model.textEncoderLoaded(lease: lease) }
        let messages = ["Jedem v sobotu na Sněžku? Vezmi pohorky", "Posílám fakturu za září, splatnost do 15.",
                        "Kocour zase rozškrábal gauč", "Objednal jsem pizzu, bude tu za půl hodiny"]
        var meant: [[Float]] = []
        for message in messages { meant.append(try #require(try await model.embedding(ofMessage: message))) }
        func best(_ words: String) async throws -> String {
            let query = try #require(try await model.embedding(ofQuery: words))
            let scores = meant.map { zip($0, query).map(*).reduce(0, +) }
            return messages[scores.indices.max { scores[$0] < scores[$1] }!]
        }
        #expect(try await best("výlet na hory") == messages[0])
        #expect(try await best("platba za služby") == messages[1])
        #expect(try await best("domácí mazlíček") == messages[2])
        #expect(try await best("jídlo s sebou") == messages[3])
    }
}

@Suite(recognizesText) struct PhotoIndexerTests {
    @Test func readsEveryPhotoOfTheDemoOnce() async throws {
        let store = try await LocalStore.open(file: folder().appending(path: "index.sqlite"), key: String(repeating: "ef", count: 32))
        let account = RustAccount.demo(rooms: 20, messagesPerRoom: 60)
        let (reports, report) = AsyncStream<SearchIndexer.Progress>.makeStream()
        let texts = SearchIndexer(store: store, account: Task { account }, maxChats: 2) { report.yield($0) }
        try await leased { lease in await texts.update(lease: lease) }
        for await progress in reports where !progress.isIndexing { break }
        let kept = try await store.imageCounts(reader: PhotoReader(model: nil).name)
        #expect(kept.total > 0 && kept.read == 0)

        let photos = PhotoIndexer(store: store, account: Task { account }, directory: folder(), model: nil) { _ in }
        #expect(try await leased { lease in await photos.read(limit: nil, lease: lease) })
        #expect(try await store.imageCounts(reader: PhotoReader(model: nil).name).withWords == kept.total)
        // nothing is left to read, and the downloads are gone.
        #expect(try await store.imagesToRead(by: PhotoReader(model: nil).name, limit: 10).isEmpty)
    }
}

/// Photos that download only when let: the first download waits for `open()`, and every
/// download then fails as offline (the photo not at fault, so the reading ends).
private actor HeldPhotos: MediaSourcePort {
    private(set) var downloads = 0
    private var held: CheckedContinuation<Void, Never>?
    private var isOpen = false
    private var started: [CheckedContinuation<Void, Never>] = []

    func sharedFile(roomId: String, eventId: String, directory: URL) async throws -> URL {
        downloads += 1
        for waiter in started { waiter.resume() }
        started = []
        if !isOpen { await withCheckedContinuation { held = $0 } }
        throw AccountFailure.offline
    }

    /// Waits until `count` downloads have started.
    func downloadsStarted(_ count: Int) async {
        while downloads < count { await withCheckedContinuation { started.append($0) } }
    }

    func open() {
        isOpen = true
        held?.resume()
        held = nil
    }
}

/// The reports of a `PhotoIndexer`, in the order it made them, for a test to await.
@MainActor
private final class Reports {
    private(set) var all: [PhotoIndexer.Progress] = []
    let changes = Changes()
    let report: @Sendable (PhotoIndexer.Progress) -> Void
    private var receiving: Task<Void, Never>?

    init() {
        let (reports, report) = AsyncStream<PhotoIndexer.Progress>.makeStream()
        self.report = { report.yield($0) }
        receiving = Task { [weak self] in
            for await progress in reports {
                self?.all.append(progress)
                self?.changes.send()
            }
        }
    }

    isolated deinit { receiving?.cancel() }

    /// Whether a report showed the reading again after one showed it stopped.
    var showedReadingAfterAStop: Bool {
        all.drop(while: \.isReading).dropFirst().contains(where: \.isReading)
    }
}

private func photoStore(photos: Int) async throws -> LocalStore {
    let store = try await LocalStore.open(file: folder().appending(path: "index.sqlite"), key: String(repeating: "ef", count: 32))
    try await store.addImages((0..<photos).map {
        IndexedImage(eventId: "$photo\($0)", roomId: "!room", senderName: "Anna", caption: "", date: .now, isOwn: false)
    })
    return store
}

extension PhotoSearch {
    /// The photo search's announcements (how far the reading is, the model).
    fileprivate func announcements() -> (Changes, AnyObject) {
        let changes = Changes()
        return (changes, self.changes.observe { changes.send() })
    }
}

@Suite struct PhotoReadingStopTests {
    @MainActor @Test func aStoppedReadingShowsStoppedAtOnceAndReadingAgainStartsAfterIt() async throws {
        let store = try await photoStore(photos: 3)
        let source = HeldPhotos()
        let reports = Reports()
        let photos = PhotoIndexer(store: store, account: Task { source }, directory: folder(), model: nil, report: reports.report)

        let first = Task { try await leased { lease in await photos.read(limit: nil, lease: lease) } }
        await source.downloadsStarted(1)
        #expect(await photos.progress().isReading)

        // the photo being read still downloads, but the reading shows stopped.
        await photos.stop()
        #expect(await photos.progress().isReading == false)

        // read again while the stopped one ends: it shows as reading, and starts after it.
        let again = Task { try await leased { lease in await photos.read(limit: nil, lease: lease) } }
        await reports.changes.until { reports.showedReadingAfterAStop }
        #expect(await source.downloads == 1)
        await source.open()
        #expect(try await first.value == false)
        #expect(try await again.value == false)
        #expect(await source.downloads == 2)
        #expect(await photos.progress().isReading == false)
    }

    @MainActor @Test func readNowAndStopShowAtTheTap() async throws {
        let source = HeldPhotos()
        let photos = PhotoSearch(store: try await photoStore(photos: 3), account: Task { source }, directory: folder())

        photos.readNow()
        #expect(photos.isReading)
        await source.downloadsStarted(1)
        await photos.pause()
        #expect(photos.isReading == false)
        // the stopped photo ends, and with it the reading (its last report made): nothing from
        // before the stop shows it reading again.
        await source.open()
        await photos.stop()
        #expect(photos.isReading == false)
    }

    @MainActor @Test func readNowWithNothingToReadEndsShowingStopped() async throws {
        let photos = PhotoSearch(store: try await photoStore(photos: 0), account: Task { HeldPhotos() }, directory: folder())
        let (changes, observing) = photos.announcements()

        photos.readNow()
        #expect(photos.isReading)
        await changes.until { !photos.isReading }
        withExtendedLifetime(observing) {}
        await photos.stop()
    }
}

@Test func aKindsNextPageAddsWhatItHasNotShownYet() {
    let chat = ChatRow(id: "!a", name: "Anna", preview: "", date: nil, unreadCount: 0)
    func link(_ id: String) -> FoundLink {
        FoundLink(eventId: id, roomId: chat.id, chat: chat, senderName: "Anna", url: "https://lux.chat/\(id)", text: "", date: .now, isOwn: false)
    }
    var hits = SearchHits(links: [link("$1"), link("$2")])
    hits.append(SearchHits(links: [link("$2"), link("$3")], files: []), of: .links)
    #expect(hits.links.map(\.eventId) == ["$1", "$2", "$3"])
    #expect(hits.count(of: .links) == 3)
    #expect(hits.count(of: .photos) == 0)
    #expect(link("$1").host == "lux.chat")
}
