import Foundation

/// Search in photos, when the user turns it on: the photos the index keeps are read on this
/// device (their words by Vision, their look by the photo search model, downloaded on turning it
/// on), and a search finds them by those, and by the messages sent near them. Nothing leaves the
/// device. On the iPhone a few new photos are read while the app is open, the rest at night
/// (`PhotoReading`, a background processing task); on the Mac all of them, quietly.
@MainActor
public final class PhotoSearch {
    /// Where photo search is, for Settings.
    public enum State: Equatable, Sendable {
        case off
        /// The model is downloading (0…1).
        case downloading(Double)
        /// The photos read, of all, and whether the reading is under way; `hasModel` is false
        /// when the model could not be had (only the words in photos are read).
        case on(read: Int, total: Int, isReading: Bool, hasModel: Bool)
    }

    public var state: State {
        guard isOn else { return .off }
        if let downloading { return .downloading(downloading) }
        return .on(read: progress.read, total: progress.total, isReading: progress.isReading, hasModel: model != nil)
    }
    public let changes = Broadcast()

    /// How far the model's download is, while it downloads.
    private var downloading: Double? { didSet { changes.send() } }
    private var progress = PhotoIndexer.Progress(read: 0, total: 0, isReading: false) { didSet { changes.send() } }

    /// How many new photos the iPhone reads at a time while the app is open; the rest wait for
    /// the night.
    #if os(iOS)
    private static let foregroundLimit: Int? = 24
    #else
    private static let foregroundLimit: Int? = nil
    #endif

    private let store: LocalStore
    private let indexer: PhotoIndexer
    private var model: PhotoSearchModel?
    private var loading: Task<Void, Never>?

    init(store: LocalStore, account: Task<RustAccount, any Error>, directory: URL) {
        self.store = store
        let (reports, report) = AsyncStream<PhotoIndexer.Progress>.makeStream(bufferingPolicy: .bufferingNewest(1))
        indexer = PhotoIndexer(store: store, account: account, directory: directory, model: nil) { report.yield($0) }
        Task { [weak self] in
            for await progress in reports { self?.progress = progress }
        }
        if Preferences.shared.searchesPhotos { start() }
    }

    public var isOn: Bool { Preferences.shared.searchesPhotos }

    /// Turns photo search on: the model downloads, and the photos are read.
    public func turnOn() {
        guard !isOn else { return }
        Preferences.shared.searchesPhotos = true
        start()
    }

    /// Turns photo search off: the reading stops, what was read and the model go.
    public func turnOff() async {
        guard isOn else { return }
        Preferences.shared.searchesPhotos = false
        loading?.cancel()
        loading = nil
        model = nil
        await indexer.stop()
        await indexer.use(nil)
        try? await store.forgetImageReads()
        await PhotoSearchAssets.remove()
        downloading = nil
        changes.send()
    }

    /// New photos came: a few of them are read now (all on the Mac).
    func update() {
        guard isOn else { return }
        // below what the user does: the reading yields to the app.
        Task(priority: .utility) { [indexer] in await indexer.read(limit: Self.foregroundLimit) }
    }

    /// Reads every photo not read yet (the iPhone's background task); true when none is left.
    public func readAll() async -> Bool {
        guard isOn else { return true }
        await loading?.value
        return await indexer.read(limit: nil)
    }

    /// Stops the reading (the system ends the background task, or the account closes).
    public func stop() async {
        await indexer.stop()
    }

    /// The photos that match `text`, the best first; none while photo search is off.
    func search(_ text: String) async -> [ImageHit] {
        guard isOn else { return [] }
        let model = self.model
        var embedding: [Float]?
        do { embedding = try await model?.embedding(of: text) } catch {
            Log.app.error("photo search: the words' embedding: \(String(describing: error), privacy: .public)")
        }
        return (try? await store.searchImages(text, embedding: embedding, minSimilarity: model?.minSimilarity ?? 1)) ?? []
    }

    /// Gets the model (downloading it the first time), then reads the photos with it; when it
    /// cannot be had, only their words.
    private func start() {
        loading?.cancel()
        loading = Task { [weak self] in await self?.loadModel() }
    }

    private func loadModel() async {
        progress = await indexer.progress()
        if await !PhotoSearchAssets.isOnDevice() { downloading = 0 }
        do {
            let folder = try await PhotoSearchAssets.modelFolder { [weak self] fraction in
                Task { @MainActor in
                    if self?.downloading != nil { self?.downloading = fraction }
                }
            }
            guard !Task.isCancelled, isOn else { return }
            let model = try PhotoSearchModel(folder: folder)
            self.model = model
            await model.prepareTextEncoder()
            await indexer.use(model)
        } catch {
            Log.app.error("photo search: no model: \(String(describing: error), privacy: .public)")
        }
        downloading = nil
        guard !Task.isCancelled, isOn else { return }
        progress = await indexer.progress()
        update()
    }
}
