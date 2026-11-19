import CoreGraphics
import CoreML
import CoreText
import Foundation
import ImageIO
import Synchronization
import Testing
import UniformTypeIdentifiers
import Vision
@testable import LuxCore

/// The folder of photo search's model (`scripts/image-search/package.sh` writes it as
/// `<out>/PhotoSearch`): the tests that need the model run only with it, as
/// `LUX_PHOTO_MODEL=<folder> swift test`.
private let modelFolder = ProcessInfo.processInfo.environment["LUX_PHOTO_MODEL"].map { URL(fileURLWithPath: $0) }

/// A new folder in the test's own (`.ownFolder`).
private func folder() throws -> URL {
    try TemporaryFolder.ofTest.appending(path: UUID().uuidString, directoryHint: .isDirectory)
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
    let file = try folder().appending(path: "receipt.png")
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

@Suite(recognizesText, .ownFolder, .timeLimit(.minutes(1))) struct PhotoReaderTests {
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
        for message in messages {
            let alone = MessageToEmbed(eventId: "", senderName: "Anna", body: message, context: [])
            meant.append(try #require(try await model.embedding(ofMessage: alone)))
        }
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

    /// A short reply is found by what it answers: read with the messages before it, which alone
    /// it does not say (scripts/image-search/evaluate-messages.py measures more of them).
    @Test(.enabled(if: modelFolder != nil, "needs the model: LUX_PHOTO_MODEL"))
    func findsAShortReplyByTheMessagesBeforeIt() async throws {
        let model = try PhotoSearchModel(folder: try #require(modelFolder))
        try await leased { lease in await model.textEncoderLoaded(lease: lease) }
        func reply(_ sender: String, _ body: String, after context: [(String, String)]) -> MessageToEmbed {
            MessageToEmbed(eventId: "", senderName: sender, body: body,
                           context: context.map { MessageToEmbed.Line(senderName: $0.0, body: $0.1) })
        }
        let replies = [
            reply("Já", "řízek, děti kapra nejí", after: [("Máma", "Kdy přijedete na Vánoce?"), ("Já", "23. odpoledne"),
                                                        ("Máma", "Co chcete k večeři, kapra nebo řízek?")]),
            reply("Ondra", "přijde ve středu ráno", after: [("Lucie", "Pračka zase teče, volala jsem opraváře")]),
            reply("Tom", "done, valid until next March", after: [("Tom", "The release build failed again, the signing certificate expired"),
                                                                 ("Me", "Can you renew it?")]),
            reply("Anna", "just wine", after: [("Anna", "yes, Friday at 5 at ours"), ("Me", "Should we bring anything?")]),
        ]
        var meant: [[Float]] = []
        for message in replies { meant.append(try #require(try await model.embedding(ofMessage: message))) }
        func best(_ words: String) async throws -> String {
            let query = try #require(try await model.embedding(ofQuery: words))
            let scores = meant.map { zip($0, query).map(*).reduce(0, +) }
            return replies[scores.indices.max { scores[$0] < scores[$1] }!].body
        }
        #expect(try await best("co bude k vánoční večeři") == replies[0].body)
        #expect(try await best("kdy přijde opravář pračky") == replies[1].body)
        #expect(try await best("how long is the signing certificate valid") == replies[2].body)
        #expect(try await best("what should we bring to dinner") == replies[3].body)
    }
}

@Suite(recognizesText, .ownPreferences, .ownFolder, .timeLimit(.minutes(1))) struct PhotoIndexerTests {
    @Test func readsEveryPhotoOfTheDemoOnce() async throws {
        let store = try await TemporaryFolder.store()
        let account = RustAccount.demo(rooms: 20, messagesPerRoom: 60)
        let (reports, report) = AsyncStream<SearchIndexer.Progress>.makeStream()
        let texts = SearchIndexer(store: store, account: Task { account }, maxChats: 2, preferences: try Preferences.ofTest) { report.yield($0) }
        try await leased { lease in await texts.update(lease: lease) }
        _ = try await reports.first { !$0.isIndexing }
        let kept = try await store.imageCounts(reader: PhotoReader(model: nil).name)
        #expect(kept.total > 0 && kept.read == 0)

        let photos = PhotoIndexer(store: store, account: Task { account }, directory: try folder(), reader: PhotoReader(model: nil)) { _ in }
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
    /// Each download as it starts.
    nonisolated let started: AsyncStream<Void>
    private let starting: AsyncStream<Void>.Continuation
    private var held: CheckedContinuation<Void, Never>?
    private var isOpen = false

    init() {
        (started, starting) = AsyncStream.makeStream()
    }

    func sharedFile(roomId: String, eventId: String, directory: URL) async throws -> URL {
        downloads += 1
        starting.yield()
        if !isOpen { await withCheckedContinuation { held = $0 } }
        throw AccountFailure.offline
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
    let store = try await TemporaryFolder.store()
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

@Suite(.ownPreferences, .ownFolder, .timeLimit(.minutes(1))) struct PhotoReadingStopTests {
    @MainActor @Test func aStoppedReadingShowsStoppedAtOnceAndReadingAgainStartsAfterIt() async throws {
        let store = try await photoStore(photos: 3)
        let source = HeldPhotos()
        let reports = Reports()
        let photos = PhotoIndexer(store: store, account: Task { source }, directory: try folder(), reader: PhotoReader(model: nil), report: reports.report)

        let first = Task { try await leased { lease in await photos.read(limit: nil, lease: lease) } }
        try await source.started.first()
        #expect(await photos.progress().isReading)

        // the photo being read still downloads, but the reading shows stopped.
        await photos.stop()
        #expect(await photos.progress().isReading == false)

        // read again while the stopped one ends: it shows as reading, and starts after it.
        let again = Task { try await leased { lease in await photos.read(limit: nil, lease: lease) } }
        try await reports.changes.until { reports.showedReadingAfterAStop }
        #expect(await source.downloads == 1)
        await source.open()
        #expect(try await first.value == false)
        #expect(try await again.value == false)
        #expect(await source.downloads == 2)
        #expect(await photos.progress().isReading == false)
    }

    @MainActor @Test func readNowAndStopShowAtTheTap() async throws {
        let source = HeldPhotos()
        let photos = PhotoSearch(store: try await photoStore(photos: 3), account: Task { source }, directory: try folder(),
                                 preferences: try Preferences.ofTest)

        let (changes, observing) = photos.announcements()
        photos.readNow()
        #expect(photos.isReading)
        try await source.started.first()
        await photos.pause()
        #expect(photos.isReading == false)
        // from the stop on, every reading shown is kept.
        var shownReadingAgain = false
        let watching = photos.changes.observe { if photos.isReading { shownReadingAgain = true } }
        // the stopped photo ends, and with it the reading (its last report made).
        await source.open()
        await photos.stop()
        // the reports arrive in order, each with the photos' counts: once the counts show, the
        // report made as the reading started (the one that said it was reading) has come, or
        // given way to a newer one.
        try await changes.until { photos.progress.total == 3 }
        #expect(!shownReadingAgain)
        #expect(photos.isReading == false)
        withExtendedLifetime((observing, watching)) {}
    }

    @MainActor @Test func readNowWithNothingToReadEndsShowingStopped() async throws {
        let photos = PhotoSearch(store: try await photoStore(photos: 0), account: Task { HeldPhotos() }, directory: try folder(),
                                 preferences: try Preferences.ofTest)
        let (changes, observing) = photos.announcements()

        photos.readNow()
        #expect(photos.isReading)
        try await changes.until { !photos.isReading }
        withExtendedLifetime(observing) {}
        await photos.stop()
    }
}

/// The model as the asset pack gives it, in a test: each getting of it fails as the next of
/// `failures` says, and once none is left, gives a model of a `model.json` only (its encoders
/// load only when a photo is read or a search made).
private actor FakeModelSource: PhotoModelSource {
    private var failures: [any Error]
    private(set) var gets = 0
    private let folder: URL

    init(failing failures: [any Error] = []) throws {
        self.failures = failures
        folder = try TemporaryFolder.ofTest.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let description = #"{"model": "fake", "side": 224, "textLength": 64, "dimension": 8, "lowercase": true, "padId": 0}"#
        try Data(description.utf8).write(to: folder.appending(path: "model.json"))
        // a tokenizer of three words, for a text encoder a test loads (`FakeEncoders`).
        let tokenizer = #"""
            {"version": "1.0", "truncation": null, "padding": null, "added_tokens": [], "normalizer": null,
             "pre_tokenizer": {"type": "Whitespace"}, "post_processor": null, "decoder": null,
             "model": {"type": "WordLevel", "vocab": {"[PAD]": 0, "[UNK]": 1, "dog": 2}, "unk_token": "[UNK]"}}
            """#
        try Data(tokenizer.utf8).write(to: folder.appending(path: "tokenizer.json"))
    }

    func isOnDevice() async -> Bool { false }

    func modelFiles(step: @escaping @Sendable (PhotoModelStep) -> Void) async throws -> PhotoSearchModel.Files {
        gets += 1
        step(.downloading(0.5))
        if !failures.isEmpty { throw failures.removeFirst() }
        step(.preparing)
        return { [folder] in folder.appending(path: $0) }
    }

    func remove() async {}
}

@Suite(.ownPreferences, .ownFolder, .timeLimit(.minutes(1))) struct PhotoModelStateTests {
    @MainActor private func photoSearch(_ assets: FakeModelSource, on: Bool) async throws -> PhotoSearch {
        let preferences = try Preferences.ofTest
        preferences.searchesPhotosByLook = on
        return PhotoSearch(store: try await photoStore(photos: 0), account: Task { HeldPhotos() }, directory: try folder(),
                           preferences: preferences, assets: assets)
    }

    @MainActor @Test func semanticSearchOnSinceTheLastLaunchGetsTheModelAtLaunch() async throws {
        let assets = try FakeModelSource()
        let photos = try await photoSearch(assets, on: true)
        let (changes, observing) = photos.announcements()
        try await changes.until { photos.looks == .ready }
        #expect(await assets.gets == 1)
        #expect(photos.searchNote() == nil)
        withExtendedLifetime(observing) {}
        await photos.stop()
    }

    @MainActor @Test func semanticSearchOffGetsNoModel() async throws {
        let assets = try FakeModelSource()
        let photos = try await photoSearch(assets, on: false)
        #expect(photos.looks == .off)
        photos.retryModel()
        #expect(photos.looks == .off)
        #expect(await assets.gets == 0)
        await photos.stop()
    }

    @MainActor @Test func aModelThatCouldNotBeHadShowsWhyAndIsReadyAfterTryAgain() async throws {
        let assets = try FakeModelSource(failing: [URLError(.notConnectedToInternet)])
        let photos = try await photoSearch(assets, on: true)
        let (changes, observing) = photos.announcements()
        try await changes.until { if case .failed = photos.looks { true } else { false } }
        #expect(photos.looks == .failed(URLError(.notConnectedToInternet).localizedDescription))
        // the search says why its photos are found by their words only, and where to try again.
        #expect(photos.searchNote()?.contains("Settings") == true)

        photos.retryModel()
        #expect(photos.looks != .failed(URLError(.notConnectedToInternet).localizedDescription))
        try await changes.until { photos.looks == .ready }
        #expect(await assets.gets == 2)
        // ready, it is not got again.
        photos.retryModel()
        #expect(photos.looks == .ready)
        #expect(await assets.gets == 2)
        withExtendedLifetime(observing) {}
        await photos.stop()
    }

    @MainActor @Test func turningSemanticSearchOnGetsTheModelAndOffLetsItGo() async throws {
        let assets = try FakeModelSource()
        let photos = try await photoSearch(assets, on: false)
        let (changes, observing) = photos.announcements()
        await photos.setSearchesByLook(true)
        try await changes.until { photos.looks == .ready }
        await photos.setSearchesByLook(false)
        #expect(photos.looks == .off)
        #expect(photos.searchNote() == nil)
        withExtendedLifetime(observing) {}
        await photos.stop()
    }
}

/// The model's encoders in a test: each loads at once and reads anything as the same made-up
/// embedding (the fake model's 8 numbers). How many times each kind loaded is counted, and each
/// encoder let go (its memory the app's again) is told on `released`. The text encoder's unused
/// time runs on `clock`.
private final class FakeEncoders: Sendable {
    let clock = TestClock()
    /// Each encoder as its memory goes.
    let released: AsyncStream<PhotoSearchModel.EncoderKind>
    private let releasing: AsyncStream<PhotoSearchModel.EncoderKind>.Continuation
    private let counts = Mutex<[PhotoSearchModel.EncoderKind: Int]>([:])
    /// The kinds that fail to load (their model's file unreadable, say).
    private let failing: Set<PhotoSearchModel.EncoderKind>

    init(failing: Set<PhotoSearchModel.EncoderKind> = []) {
        self.failing = failing
        (released, releasing) = AsyncStream.makeStream()
    }

    func loads(_ kind: PhotoSearchModel.EncoderKind) -> Int {
        counts.withLock { $0[kind, default: 0] }
    }

    var encoders: PhotoSearchModel.Encoders {
        PhotoSearchModel.Encoders(load: { [self] kind, _ in
            self.counts.withLock { $0[kind, default: 0] += 1 }
            if self.failing.contains(kind) { throw PhotoSearchError.unexpectedModel }
            return Encoder(kind: kind, gone: self.releasing)
        }, clock: clock)
    }

    private final class Encoder: EmbeddingEncoder {
        let kind: PhotoSearchModel.EncoderKind
        let gone: AsyncStream<PhotoSearchModel.EncoderKind>.Continuation

        init(kind: PhotoSearchModel.EncoderKind, gone: AsyncStream<PhotoSearchModel.EncoderKind>.Continuation) {
            self.kind = kind
            self.gone = gone
        }

        deinit { gone.yield(kind) }

        func prediction(from input: any MLFeatureProvider) throws -> any MLFeatureProvider {
            let embedding = try MLMultiArray(shape: [8], dataType: .float32)
            for index in 0..<8 { embedding[index] = 0.5 }
            return try MLDictionaryFeatureProvider(dictionary: ["embedding": embedding])
        }

        func input(_ image: CGImage) throws -> any MLFeatureProvider {
            try MLDictionaryFeatureProvider(dictionary: [:])
        }
    }
}

/// Which of the model's encoders is kept, and when each goes and loads again: each only while it
/// is used, so a Mac app left open does not hold them.
@Suite(.ownPreferences, .ownFolder, .timeLimit(.minutes(1))) struct PhotoModelMemoryTests {
    private func model(_ fake: FakeEncoders) async throws -> PhotoSearchModel {
        try PhotoSearchModel(files: try await FakeModelSource().modelFiles { _ in }, encoders: fake.encoders)
    }

    private func photo() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        return try #require(context.makeImage())
    }

    @Test func theTextEncoderGoesOnceUnusedForItsIdleTimeAndTheNextSearchLoadsItAgain() async throws {
        let fake = FakeEncoders()
        let model = try await model(fake)
        let idle = PhotoSearchModel.textIdle
        try await leased { lease in await model.textEncoderLoaded(lease: lease) }
        _ = try await fake.clock.sleeps.first { $0 == fake.clock.now.advanced(by: idle) }

        // a search just before the idle time ends keeps it a whole idle time from then.
        fake.clock.advance(by: idle - .seconds(1))
        #expect(try await model.embedding(ofQuery: "dog") != nil)
        _ = try await fake.clock.sleeps.first { $0 == fake.clock.now.advanced(by: idle) }
        fake.clock.advance(by: .seconds(1))
        #expect(await model.isTextEncoderReady)

        // unused for the idle time: it goes, and searches find photos by their words meanwhile.
        fake.clock.advance(by: idle)
        _ = try await fake.released.first { $0 == .text }
        #expect(await !model.isTextEncoderReady)
        #expect(try await model.embedding(ofQuery: "dog") == nil)

        // the next search loads it again.
        try await leased { lease in await model.textEncoderLoaded(lease: lease) }
        #expect(try await model.embedding(ofQuery: "dog") != nil)
        #expect(fake.loads(.text) == 2)
        await model.close()
    }

    @Test func theImageEncoderIsKeptForTheWholeReadingAndGoesWhenItEnds() async throws {
        let fake = FakeEncoders()
        let model = try await model(fake)
        let image = try photo()
        for _ in 0..<3 {
            _ = try await leased { lease in try await model.embedding(of: image, lease: lease) }
        }
        #expect(fake.loads(.image) == 1)

        await PhotoReader(model: model).rest()
        _ = try await fake.released.first { $0 == .image }
        // new photos to read: it loads again for them.
        _ = try await leased { lease in try await model.embedding(of: image, lease: lease) }
        #expect(fake.loads(.image) == 2)
        // the text encoder never loaded for photos.
        #expect(fake.loads(.text) == 0)
        await model.close()
    }

    @Test func bothEncodersGoWhenTheAppLeavesTheFrontOrMemoryRunsShort() async throws {
        let fake = FakeEncoders()
        let model = try await model(fake)
        let image = try photo()
        _ = try await leased { lease in try await model.embedding(of: image, lease: lease) }
        try await leased { lease in await model.textEncoderLoaded(lease: lease) }

        await model.releaseEncoders()
        let gone = await fake.released.prefix(2).reduce(into: Set()) { $0.insert($1) }
        #expect(gone == [.image, .text])
        #expect(await !model.isTextEncoderReady)
        await model.close()
    }

    private func messages(_ ids: Range<Int>) -> [IndexedMessage] {
        ids.map { IndexedMessage(eventId: "$m\($0)", roomId: "!room", senderName: "Anna", body: "dog number \($0) on the beach",
                                 date: Date(timeIntervalSince1970: 1_700_000_000 + Double($0) * 60), isOwn: false) }
    }

    @Test func messagesReadAfterTheTextEncoderWentLoadItAgainForTheirBatch() async throws {
        let fake = FakeEncoders()
        let model = try await model(fake)
        let store = try await TemporaryFolder.store()
        try await store.add(messages(0..<3))
        let meaning = MessageMeaning(store: store)
        await meaning.use(model)
        #expect(try await leased { lease in await meaning.read(limit: nil, lease: lease) })
        #expect(await meaning.progress().read == 3)
        _ = try await fake.clock.sleeps.first { $0 == fake.clock.now.advanced(by: PhotoSearchModel.textIdle) }

        // unused for the idle time: it goes; the next messages' batch loads it again.
        fake.clock.advance(by: PhotoSearchModel.textIdle)
        _ = try await fake.released.first { $0 == .text }
        try await store.add(messages(3..<5))
        #expect(try await leased { lease in await meaning.read(limit: nil, lease: lease) })
        #expect(await meaning.progress().read == 5)
        #expect(fake.loads(.text) == 2)
        await model.close()
    }

    @Test func messagesTheTextEncoderCannotReadStayUnread() async throws {
        let fake = FakeEncoders(failing: [.text])
        let model = try await model(fake)
        let store = try await TemporaryFolder.store()
        try await store.add(messages(0..<3))
        let meaning = MessageMeaning(store: store)
        await meaning.use(model)
        // no encoder: no message counts as read, each waits for the next reading.
        #expect(try await leased { lease in await meaning.read(limit: nil, lease: lease) } == false)
        let progress = await meaning.progress()
        #expect(progress.total == 3 && progress.read == 0)
        await model.close()
    }

    @MainActor @Test func aSearchAfterTheTextEncoderWentLoadsItAgainAndFindsPhotosByTheirLookOnceItHas() async throws {
        let fake = FakeEncoders()
        let preferences = try Preferences.ofTest
        preferences.searchesPhotosByLook = true
        let photos = PhotoSearch(store: try await photoStore(photos: 0), account: Task { HeldPhotos() }, directory: try folder(),
                                 preferences: preferences, assets: try FakeModelSource(), encoders: fake.encoders)
        let (changes, observing) = photos.announcements()
        try await changes.until { photos.looks == .ready }

        // the first search loads it, finding photos by their words meanwhile. (The fake loads at
        // once: it may be ready before the wait, which then has nothing to wait for.)
        #expect(await photos.embedding(of: "dog") == nil)
        _ = await photos.waitForLook()
        #expect(await !photos.isLookPending)
        _ = try await fake.clock.sleeps.first { $0 == fake.clock.now.advanced(by: PhotoSearchModel.textIdle) }

        fake.clock.advance(by: PhotoSearchModel.textIdle)
        _ = try await fake.released.first { $0 == .text }
        #expect(await photos.isLookPending)
        // a search after it went: by the words now, by the look once it has loaded again.
        #expect(await photos.embedding(of: "dog") == nil)
        _ = await photos.waitForLook()
        #expect(await photos.embedding(of: "dog") != nil)
        #expect(fake.loads(.text) == 2)
        withExtendedLifetime(observing) {}
        await photos.stop()
    }
}

/// The model's copy, which Core ML loads from in place of the asset pack's folder.
@Suite(.ownFolder) struct PhotoModelCopyTests {
    /// Two photo searches that ask for the model at once (a session closing as the next opens)
    /// both get the one copy: neither removes the other's, nor fails finding it in place.
    @Test func twoCopiesAskedForAtOnceBothGetTheOneCopy() async throws {
        let root = try folder()
        let source = try pack("one")
        let copies = try await withThrowingTaskGroup(of: URL.self) { group in
            for _ in 0..<4 {
                group.addTask { try await PhotoSearchAssets.copiedInTurn(of: Data("one".utf8), in: root) { source } }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(Set(copies).count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == [try #require(copies.first).lastPathComponent])
    }

    /// A model's folder as a pack holds it: `model.json` saying `name`, and an encoder's folder.
    private func pack(_ name: String) throws -> URL {
        let pack = try folder()
        try FileManager.default.createDirectory(at: pack.appending(path: "Encoders.mlmodelc"), withIntermediateDirectories: true)
        try Data(name.utf8).write(to: pack.appending(path: "model.json"))
        try Data("weights".utf8).write(to: pack.appending(path: "Encoders.mlmodelc/weights.bin"))
        return pack
    }

    @Test func aModelIsCopiedOnceAndLoadsFromTheSamePlaceEachTime() throws {
        let root = try folder()
        let source = try pack("one")
        var lookups = 0
        let first = try PhotoSearchAssets.copied(of: Data("one".utf8), in: root) { lookups += 1; return source }
        let again = try PhotoSearchAssets.copied(of: Data("one".utf8), in: root) { lookups += 1; return source }
        #expect(lookups == 1)
        #expect(again == first)
        #expect(try String(contentsOf: first.appending(path: "model.json"), encoding: .utf8) == "one")
        #expect(FileManager.default.fileExists(atPath: first.appending(path: "Encoders.mlmodelc/weights.bin").path))
        #expect(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    /// The pack's version says nothing here: only what its model.json says, which changes with
    /// any of its files (`package.sh`).
    @Test func aChangedModelIsCopiedAgainAndReplacesTheOldCopyAndWhatAnEndedCopyLeft() throws {
        let root = try folder()
        let old = try PhotoSearchAssets.copied(of: Data("old".utf8), in: root) { try pack("old") }
        // a copy the app was ended in the middle of.
        try FileManager.default.createDirectory(at: root.appending(path: "\(UUID().uuidString).partial"), withIntermediateDirectories: true)
        let new = try PhotoSearchAssets.copied(of: Data("new".utf8), in: root) { try pack("new") }
        #expect(new != old)
        #expect(try String(contentsOf: new.appending(path: "model.json"), encoding: .utf8) == "new")
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == [new.lastPathComponent])
    }

    @Test func aFailedLookupLeavesNoCopy() throws {
        let root = try folder()
        #expect(throws: PhotoSearchError.unexpectedModel) {
            try PhotoSearchAssets.copied(of: Data("one".utf8), in: root) { throw PhotoSearchError.unexpectedModel }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
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
