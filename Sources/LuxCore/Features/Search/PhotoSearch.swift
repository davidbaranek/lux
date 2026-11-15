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
        didSet { if progress != oldValue { changes.send() } }
    }
    public let changes = Broadcast()

    /// Search finds photos by how they look (the model); the words in them are found always.
    public var searchesByLook: Bool { Preferences.shared.searchesPhotosByLook }

    /// How far the model's download is, while it downloads, in whole percent: the download reports
    /// far more often than anyone reads it, and each change lays Settings out again.
    private var downloading: Double? { didSet { if downloading != oldValue { changes.send() } } }

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
    private var saving: AnyObject?

    init(store: LocalStore, account: Task<RustAccount, any Error>, directory: URL) {
        self.store = store
        let (reports, report) = AsyncStream<PhotoIndexer.Progress>.makeStream(bufferingPolicy: .bufferingNewest(1))
        indexer = PhotoIndexer(store: store, account: account, directory: directory, model: nil) { report.yield($0) }
        Task { [weak self] in
            for await progress in reports { self?.progress = progress }
        }
        // the battery or the data saved no more: the waiting photos are read (Settings shows the
        // change either way).
        saving = Saving.shared.changes.observe { [weak self] in
            self?.changes.send()
            self?.update()
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

    /// New photos came: a few of them are read now (all on the Mac), unless the device saves its
    /// battery or data; then they wait for the next time, or for it to charge.
    func update() {
        // while the model loads, the photos wait: they are read once, with it.
        guard loading == nil, Saving.shared.reason == nil else { return }
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

    /// Why photos cannot be read now: the device saves its battery or data. Nil when they can.
    public var readNowBlocked: Saving.Reason? { Saving.shared.reason }

    /// Reads every photo not read yet, now (the user asked), unless the device saves its battery
    /// or data.
    public func readNow() {
        guard readNowBlocked == nil else { return }
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

    /// The photos that match `text`, the best first; `roomIds` keeps those rooms' (a chat's
    /// details), each room's best first.
    func search(_ text: String, in roomIds: [String]? = nil) async -> [ImageHit] {
        let model = self.model
        var embedding: [Float]?
        do { embedding = try await model?.embedding(of: text) } catch {
            Log.app.error("photo search: the words' embedding: \(String(describing: error), privacy: .public)")
        }
        let minSimilarity = model?.minSimilarity ?? 1
        guard let roomIds else {
            return (try? await store.searchImages(text, embedding: embedding, minSimilarity: minSimilarity)) ?? []
        }
        var hits: [ImageHit] = []
        for roomId in roomIds {
            hits += (try? await store.searchImages(text, embedding: embedding, minSimilarity: minSimilarity, in: roomId, limit: 120)) ?? []
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
            await indexer.use(model)
            progress = await indexer.progress()
        } catch {
            Log.app.error("photo search: no model: \(String(describing: error), privacy: .public)")
        }
    }
}
