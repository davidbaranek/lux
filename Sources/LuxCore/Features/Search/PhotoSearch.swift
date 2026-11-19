import Foundation

/// Search in photos, all on this device. Always: the words in each photo (Vision) and the
/// messages sent near it. When the user turns semantic search on: how photos look too, by the
/// search model (downloaded then, about 650 MB), so "dog on the beach" finds one with no
/// words at all; the same model reads what messages mean (`MessageMeaning`).
/// Nothing leaves the device. Photos are read while the app is open, quietly (the iPhone gives an
/// app's reading in the background too little time to be worth it).
@MainActor
public final class PhotoSearch {
    /// Where the search by how photos look is, for Settings and the search's note.
    public enum Looks: Equatable, Sendable {
        case off
        /// The model is downloading (0…1, in whole percent: the download reports far more often
        /// than anyone reads it, and each change lays Settings out again).
        case downloading(Double)
        /// The model is on the device, and the app makes it ready (copies and opens it).
        case preparing
        /// Photos are found by how they look.
        case ready
        /// The model could not be had, for the reason given: photos are found by their words
        /// only until it is tried again (`retryModel`, the network back, the app back in front).
        case failed(String)
    }

    /// Where the model is; `.off` while the search by look is.
    public private(set) var looks = Looks.off {
        didSet { if looks != oldValue { changes.send() } }
    }
    /// The photos read by the current reader, of all, and whether the reading is under way.
    public private(set) var progress = PhotoIndexer.Progress() {
        didSet { if progress != oldValue { changes.send() } }
    }
    public let changes = Broadcast()

    /// The model came or went: messages are read with it too (search by meaning).
    var onModel: ((PhotoSearchModel?) -> Void)?

    /// Search finds photos by how they look (the model); the words in them are found always.
    public var searchesByLook: Bool { preferences.searchesPhotosByLook }

    private let store: LocalStore
    private let preferences: Preferences
    private let indexer: PhotoIndexer
    private let assets: any PhotoModelSource
    private var model: PhotoSearchModel?
    private var loading: Task<Void, Never>?
    /// Which getting of the model `loading` is: one replaced ends without clearing the next.
    private var loadings = 0
    private var saving: AnyObject?
    /// The app left the front: the model's encoders go until it is back.
    private var leaving: AnyObject?
    /// The app came back to the front, or the device to a network: a model that could not be
    /// had is tried again.
    private var returning: AnyObject?
    private var reconnecting: AnyObject?
    /// The system's memory pressure: the model's encoders go when memory runs short.
    private let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)

    init(store: LocalStore, account: Task<any MediaSourcePort, any Error>, directory: URL, preferences: Preferences,
         assets: any PhotoModelSource = PhotoSearchAssets()) {
        self.store = store
        self.preferences = preferences
        self.assets = assets
        let (reports, report) = AsyncStream<PhotoIndexer.Progress>.makeStream(bufferingPolicy: .bufferingNewest(1))
        indexer = PhotoIndexer(store: store, account: account, directory: directory, reader: PhotoReader(model: nil)) { report.yield($0) }
        Task { [weak self] in
            for await progress in reports { self?.reported = progress }
        }
        // the battery or the data saved no more: the waiting photos are read (Settings shows the
        // change either way).
        saving = Saving.shared.changes.observe { [weak self] in
            self?.changes.send()
            self?.update()
        }
        // on since an earlier launch: the model is got now, as when the user turns it on.
        if searchesByLook { loadModel() }
        leaving = ForegroundWork.shared.onLeave { [weak self] in self?.releaseMemory() }
        returning = ForegroundWork.shared.onReturn { [weak self] in self?.retryModel() }
        reconnecting = Saving.shared.reconnected.observe { [weak self] in self?.retryModel() }
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
        preferences.searchesPhotosByLook = on
        if on {
            loadModel()
            return
        }
        loading?.cancel()
        loading = nil
        let closing = model
        model = nil
        onModel?(nil)
        looks = .off
        await indexer.stop()
        await indexer.use(PhotoReader(model: nil))
        await bestEffort("photo search: forget the looks") { try await store.forgetImageEmbeddings(reader: PhotoReader(model: nil).name) }
        // the model's files go once none of its encoders loads from them.
        await closing?.close()
        await assets.remove()
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
        // the model is not got for a search that ended (its session closed): the next session's
        // gets it.
        loading?.cancel()
        loading = nil
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
        case .preparing:
            return String(localized: "Photos by what they show: the model is being prepared.")
        case .failed:
            return String(localized: "Photos are found by their words only: the model could not be downloaded. Try again in Settings › Search.")
        case .ready:
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

    /// The app left the front, or the system is short of memory: the model's encoders go until
    /// the next photo read or search.
    public func releaseMemory() {
        Task { await model?.releaseEncoders() }
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
        loadings += 1
        let id = loadings
        // until the system says whether it downloads.
        looks = .preparing
        loading = Task { [weak self] in
            await self?.getModel()
            guard let self, loadings == id else { return }
            loading = nil
            update()
        }
    }

    /// Gets the model again, if it could not be had: the user asked (Settings' Try Again), or
    /// what it failed for may have passed (the network is back, the app back in front).
    public func retryModel() {
        guard searchesByLook, loading == nil, case .failed = looks else { return }
        loadModel()
    }

    private func getModel() async {
        let isOnDevice = await assets.isOnDevice()
        guard !Task.isCancelled else { return }
        looks = isOnDevice ? .preparing : .downloading(0)
        do {
            let files = try await assets.modelFiles { [weak self] step in
                Task { @MainActor in self?.show(step) }
            }
            guard !Task.isCancelled, searchesByLook else { return }
            let model = try PhotoSearchModel(files: files)
            self.model = model
            looks = .ready
            onModel?(model)
            await indexer.use(PhotoReader(model: model))
            await indexer.announce()
        } catch where Task.isCancelled {
            // turned off, or the search ended: whoever cancelled it says where the model is.
        } catch {
            Log.app.error("photo search: no model: \(String(describing: error), privacy: .public)")
            looks = .failed(error.localizedDescription)
        }
    }

    /// How far getting the model is, while it is under way: a step heard after it ended (it
    /// came on a task of its own) changes nothing.
    private func show(_ step: PhotoModelStep) {
        switch (step, looks) {
        case (.downloading(let fraction), .downloading):
            looks = .downloading((fraction * 100).rounded(.down) / 100)
        case (.preparing, .downloading):
            looks = .preparing
        default:
            break
        }
    }
}
