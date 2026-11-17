import Foundation

/// Search in photos, all on this device. Always: the words in each photo (Vision) and the
/// messages sent near it. When the user turns semantic search on: how photos look too, by the
/// search model (downloaded then, about 650 MB), so "dog on the beach" finds one with no
/// words at all; the same model reads what messages mean (`MessageMeaning`).
/// Nothing leaves the device. Photos are read while the app is open, quietly (the iPhone gives an
/// app's reading in the background too little time to be worth it).
@MainActor
public final class PhotoSearch {
    /// Where the search by how photos look is, for Settings.
    public enum Looks: Equatable, Sendable {
        case off
        /// The model is downloading (0…1).
        case downloading(Double)
        /// On; `hasModel` is false when the model could not be had (only the words are read).
        case on(hasModel: Bool)
    }

    public var looks: Looks {
        guard searchesByLook else { return .off }
        if let downloading { return .downloading(downloading) }
        return .on(hasModel: model != nil)
    }
    /// The photos read by the current reader, of all, and whether the reading is under way.
    public private(set) var progress = PhotoIndexer.Progress() {
        didSet { if progress != oldValue { changes.send() } }
    }
    public let changes = Broadcast()

    /// The model came or went: messages are read with it too (search by meaning).
    var onModel: ((PhotoSearchModel?) -> Void)?

    /// Search finds photos by how they look (the model); the words in them are found always.
    public var searchesByLook: Bool { Preferences.shared.searchesPhotosByLook }

    /// How far the model's download is, while it downloads, in whole percent: the download reports
    /// far more often than anyone reads it, and each change lays Settings out again.
    private var downloading: Double? { didSet { if downloading != oldValue { changes.send() } } }

    private let store: LocalStore
    private let indexer: PhotoIndexer
    private var model: PhotoSearchModel?
    private var loading: Task<Void, Never>?
    private var saving: AnyObject?
    /// The system's memory pressure: the text encoder goes when memory runs short.
    private let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)

    init(store: LocalStore, account: Task<any MediaSourcePort, any Error>, directory: URL) {
        self.store = store
        let (reports, report) = AsyncStream<PhotoIndexer.Progress>.makeStream(bufferingPolicy: .bufferingNewest(1))
        indexer = PhotoIndexer(store: store, account: account, directory: directory, model: nil) { report.yield($0) }
        Task { [weak self] in
            for await progress in reports { self?.reported = progress }
        }
        // the battery or the data saved no more: the waiting photos are read (Settings shows the
        // change either way).
        saving = Saving.shared.changes.observe { [weak self] in
            self?.changes.send()
            self?.update()
        }
        if searchesByLook { loadModel() }
        pressure.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.releaseMemory() }
        }
        pressure.activate()
    }

    deinit { pressure.cancel() }

    /// The indexer's newest report. Its reports come in order, each true when it was made; one
    /// made before a tap may arrive after it, which is why the reading shown is not this alone.
    private var reported = PhotoIndexer.Progress() { didSet { show() } }
    /// The Read Nows the user asked for that have not ended: one waits for the model before the
    /// indexer hears of it, so only this side knows it from the tap on.
    private var readingsNow = 0 { didSet { show() } }
    /// The user stopped the reading in Settings: it stays stopped while the app runs, new photos
    /// or not, until they read the waiting photos now (or the app opens again).
    private var isPaused = false { didSet { show() } }

    /// The indexer's counts, and the reading as each side knows it: what the user asked (a stop, a
    /// Read Now still under way) shows at the tap, without waiting for the indexer's answer, and
    /// a report from before the tap cannot undo it, since it holds until the user changes it.
    private func show() {
        var shown = reported
        shown.isReading = !isPaused && (readingsNow > 0 || reported.isReading)
        progress = shown
    }

    /// The photos' reading and the model's loading: they end with the photo search.
    private let work = ForegroundJobs()

    /// Turns the search by how photos look on (the model downloads, every photo is read again
    /// with it) or off (the model and the photos' embeddings go; their words stay).
    public func setSearchesByLook(_ on: Bool) async {
        guard on != searchesByLook else { return }
        Preferences.shared.searchesPhotosByLook = on
        if on {
            loadModel()
            return
        }
        loading?.cancel()
        loading = nil
        model = nil
        onModel?(nil)
        downloading = nil
        await indexer.stop()
        await indexer.use(nil)
        await bestEffort("photo search: forget the looks") { try await store.forgetImageEmbeddings(reader: PhotoReader(model: nil).name) }
        await PhotoSearchAssets.remove()
        await indexer.announce()
        update()
    }

    /// New photos came: they are read now, unless the device saves its battery or data (then
    /// they wait for the next time).
    func update() {
        // while the model loads, the photos wait: they are read once, with it. Stopped by the
        // user, they wait for Read Now (or the next launch).
        guard loading == nil, Saving.shared.reason == nil, !isPaused else { return }
        work.start("photos") { [indexer] lease in await indexer.read(limit: nil, lease: lease) }
    }

    /// Photos are being read now.
    public var isReading: Bool { progress.isReading }
    /// Some photos wait to be read.
    public var hasUnread: Bool { progress.read < progress.total }

    /// Why photos cannot be read now: the device saves its battery or data. Nil when they can.
    public var readNowBlocked: Saving.Reason? { Saving.shared.reason }

    /// Reads every photo not read yet, now (the user asked), unless the device saves its battery
    /// or data.
    public func readNow() {
        guard readNowBlocked == nil else { return }
        isPaused = false
        guard work.start("photos now", { [weak self] lease in await self?.readNow(lease: lease) }) else { return }
        readingsNow += 1
    }

    private func readNow(lease: ForegroundLease) async {
        _ = await readAll(lease: lease)
        readingsNow -= 1
    }

    /// Reads every photo not read yet; true when none is left.
    func readAll(lease: ForegroundLease) async -> Bool {
        await loading?.value
        // stopped while the model loaded: the stop holds.
        guard !isPaused else { return false }
        return await indexer.read(limit: nil, lease: lease)
    }

    /// Stops the reading (the system ending a background task, or the account closing); what was
    /// read stays, and the rest is read the next time new photos come or the app opens.
    public func stop() async {
        await indexer.stop()
        await work.end()
    }

    /// The user stopped the reading: it stays stopped while the app runs, new photos or not,
    /// until they read the waiting photos now (or the app opens again).
    public func pause() async {
        isPaused = true
        await indexer.stop()
    }

    /// Someone is about to search: the text encoder loads now, off the main actor, so the first
    /// query finds photos by their look too. It loads in about a second once Core ML has compiled
    /// it on this device (some 20 s the first time), and is kept only from the first search on.
    public func prepareForSearch() {
        guard let model else { return }
        work.start("text encoder", priority: .userInitiated) { lease in
            await model.prepareTextEncoder(lease: lease)
        }
    }

    /// The model is on the device but its text encoder still loads: searches find photos by
    /// their words only for now.
    public var isLookPending: Bool {
        get async {
            guard let model else { return false }
            return await !model.isTextEncoderReady
        }
    }

    /// Why a search's photos may be incomplete, in words; nil when nothing is missing. (While
    /// the text encoder loads, `isLookPending`, the photos found by their look follow.)
    public func searchNote() -> String? {
        switch looks {
        case .off:
            return nil
        case .downloading(let fraction):
            return String(localized: "Photos by what they show: the model is downloading · \(fraction.formatted(.percent.precision(.fractionLength(0))))")
        case .on(hasModel: false):
            return String(localized: "Photos are found by their words only: the model is not available.")
        case .on(hasModel: true):
            guard hasUnread else { return nil }
            let left = max(progress.total - progress.read, 0)
            return String(localized: "\(left.formatted(.number)) photos not read yet: some may be missing.")
        }
    }

    /// Waits while the text encoder loads; true when it was loading and is ready now, so a search
    /// made meanwhile (which found photos by their words only) is worth making again.
    public func waitForLook() async -> Bool {
        guard let model, await !model.isTextEncoderReady else { return false }
        await model.textEncoderPrepared()
        return await model.isTextEncoderReady
    }

    /// The system is short of memory: the text encoder goes until the next search.
    public func releaseMemory() {
        Task { await model?.releaseTextEncoder() }
    }

    /// The photos that match `text`, the best first; `roomIds` keeps those rooms' (a chat's
    /// details), each room's best first.
    func search(_ text: String, in roomIds: [String]? = nil, limit: Int = 30) async -> [ImageHit] {
        await search(text, embedding: await embedding(of: text), in: roomIds, limit: limit)
    }

    /// The words' embedding, in the photos' space; nil while the model or its text encoder is not
    /// ready. A search of messages by meaning starts from it too.
    func embedding(of text: String) async -> [Float]? {
        do { return try await model?.embedding(ofQuery: text) } catch {
            Log.app.error("photo search: the words' embedding: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// The photos that match `text`, and look like `embedding`, the best first.
    func search(_ text: String, embedding: [Float]?, in roomIds: [String]? = nil, limit: Int = 30) async -> [ImageHit] {
        let minSimilarity = model?.minSimilarity ?? 1
        guard let roomIds else {
            return await bestEffort("photo search") {
                try await store.searchImages(text, embedding: embedding, minSimilarity: minSimilarity, limit: limit)
            } ?? []
        }
        var hits: [ImageHit] = []
        for roomId in roomIds {
            hits += await bestEffort("photo search in a chat") {
                try await store.searchImages(text, embedding: embedding, minSimilarity: minSimilarity, in: roomId, limit: 120)
            } ?? []
        }
        return hits
    }

    /// Gets the model (downloading it the first time), then reads the photos with it; when it
    /// cannot be had, only their words.
    private func loadModel() {
        loading?.cancel()
        loading = Task { [weak self] in
            await self?.getModel()
            self?.loading = nil
            self?.update()
        }
    }

    private func getModel() async {
        if await !PhotoSearchAssets.isOnDevice() { downloading = 0 }
        defer { downloading = nil }
        do {
            let files = try await PhotoSearchAssets.modelFiles { [weak self] fraction in
                Task { @MainActor in
                    if self?.downloading != nil { self?.downloading = (fraction * 100).rounded(.down) / 100 }
                }
            }
            guard !Task.isCancelled, searchesByLook else { return }
            let model = try PhotoSearchModel(files: files)
            self.model = model
            onModel?(model)
            await indexer.use(model)
            await indexer.announce()
        } catch {
            Log.app.error("photo search: no model: \(String(describing: error), privacy: .public)")
        }
    }
}
