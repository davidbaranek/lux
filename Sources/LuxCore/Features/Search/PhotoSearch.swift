import Foundation

/// Search in photos, all on this device. Always: the words in each photo (Vision) and the
/// messages sent near it. When the user turns it on: how photos look too, by the photo search
/// model (downloaded then, about 450 MB), so "dog on the beach" finds one with no words at all.
/// Nothing leaves the device. On the iPhone a few new photos are read while the app is open, the
/// rest while it charges (`PhotoReading`, a background processing task); on the Mac all of them,
/// quietly.
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
        didSet { changes.send() }
    }
    public let changes = Broadcast()

    /// Search finds photos by how they look (the model); the words in them are found always.
    public var searchesByLook: Bool { Preferences.shared.searchesPhotosByLook }

    /// How far the model's download is, while it downloads.
    private var downloading: Double? { didSet { changes.send() } }

    /// How many new photos the iPhone reads at a time while the app is open; the rest wait for
    /// it to charge.
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
        if searchesByLook { loadModel() }
    }

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
        downloading = nil
        await indexer.stop()
        await indexer.use(nil)
        try? await store.forgetImageEmbeddings(reader: PhotoReader(model: nil).name)
        await PhotoSearchAssets.remove()
        progress = await indexer.progress()
        update()
    }

    /// New photos came: a few of them are read now (all on the Mac).
    func update() {
        // while the model loads, the photos wait: they are read once, with it.
        guard loading == nil else { return }
        // below what the user does: the reading yields to the app.
        Task(priority: .utility) { [indexer] in await indexer.read(limit: Self.foregroundLimit) }
    }

    /// Photos are being read now.
    public var isReading: Bool { progress.isReading }
    /// Some photos wait to be read.
    public var hasUnread: Bool { progress.read < progress.total }

    /// Set by the iPhone app: reading every photo now runs as a continued processing task, which
    /// the system shows as a Live Activity and keeps going when the user leaves the app.
    public var onReadNow: (() -> Void)?

    /// Reads every photo not read yet, now (the user asked).
    public func readNow() {
        if let onReadNow { onReadNow() } else { Task(priority: .utility) { await readAll() } }
    }

    /// Reads every photo not read yet (the iPhone's background tasks); true when none is left.
    public func readAll() async -> Bool {
        await loading?.value
        return await indexer.read(limit: nil)
    }

    /// Stops the reading (the user, the system ending a background task, or the account closing);
    /// what was read stays, and the rest is read the next time the app opens or charges.
    public func stop() async {
        await indexer.stop()
    }

    /// The photos that match `text`, the best first.
    func search(_ text: String) async -> [ImageHit] {
        let model = self.model
        var embedding: [Float]?
        do { embedding = try await model?.embedding(of: text) } catch {
            Log.app.error("photo search: the words' embedding: \(String(describing: error), privacy: .public)")
        }
        return (try? await store.searchImages(text, embedding: embedding, minSimilarity: model?.minSimilarity ?? 1)) ?? []
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
            let folder = try await PhotoSearchAssets.modelFolder { [weak self] fraction in
                Task { @MainActor in
                    if self?.downloading != nil { self?.downloading = fraction }
                }
            }
            guard !Task.isCancelled, searchesByLook else { return }
            let model = try PhotoSearchModel(folder: folder)
            self.model = model
            await model.prepareTextEncoder()
            await indexer.use(model)
            progress = await indexer.progress()
        } catch {
            Log.app.error("photo search: no model: \(String(describing: error), privacy: .public)")
        }
    }
}
