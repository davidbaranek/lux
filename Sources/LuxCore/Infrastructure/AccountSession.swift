import Foundation

/// A signed-in account and everything that is its own: the account in the Rust core, its stores,
/// its models and its search. It is made whole when the account opens and ends in one place
/// (`close`): letting go of it lets go of all of it.
@MainActor
final class AccountSession {
    /// The account in the Rust core, open or still opening (its kept list shows meanwhile).
    let account: Task<RustAccount, any Error>
    /// Where the chat lists come from: the Rust core's view model over the account.
    let chatListSource: ChatListSource
    let images: ImagePipeline
    let uploads: Uploads
    let networks: NetworksModel
    let security: SecurityModel
    let profile: ProfileModel
    /// Search, once its index has opened (a moment after the account).
    private(set) var search: MessageSearch? {
        didSet { searchChanged() }
    }

    /// The account's files (the demo's in a temporary folder).
    let files: AccountPaths
    /// The account's encrypted store in the group: the last chat list, which the share extension
    /// reads too.
    let keptStore: Task<LocalStore?, Never>
    /// The account's search index, in the app's own container.
    let index: Task<LocalStore?, Never>

    private let searchChanged: @MainActor () -> Void
    private var watchingEnd: Task<Void, Never>?
    private var opening: Task<Void, Never>?

    /// Opens the account's stores, at `files`, with `key`.
    static func stores(_ files: AccountPaths, key: @escaping @Sendable () async throws -> String)
        -> (kept: Task<LocalStore?, Never>, index: Task<LocalStore?, Never>) {
        (open(files.keptStore, key: key), open(files.index, key: key))
    }

    /// Makes the account's models over `account` (open or opening), its search once the index
    /// opens; `ended` runs if the server ends this device's session.
    init(account: Task<RustAccount, any Error>, chatListSource: ChatListSource, server: String,
         files: AccountPaths, paths: AppPaths, stores: (kept: Task<LocalStore?, Never>, index: Task<LocalStore?, Never>),
         maxChats: Int? = nil, searchChanged: @escaping @MainActor () -> Void, ended: @escaping @MainActor () async -> Void) {
        self.account = account
        self.chatListSource = chatListSource
        self.files = files
        keptStore = stores.kept
        index = stores.index
        self.searchChanged = searchChanged
        images = ImagePipeline(account: account, directory: paths.media)
        uploads = Uploads(account: Task { try await account.value }, directory: paths.outgoing)
        networks = NetworksModel(account: Task { try await account.value }, server: server)
        security = SecurityModel(account: Task { try await account.value })
        profile = ProfileModel(account: Task { try await account.value })
        // the server may end the session (its tokens refused): the device is gone, sign in again.
        watchingEnd = Task {
            guard let ends = await bestEffort("watch the session's end", { try await account.value.sessionEnd() }) else { return }
            for await _ in ends {
                Log.app.error("the server ended the session")
                await ended()
                return
            }
        }
        opening = Task { [weak self, index = stores.index, kept = stores.kept, photos = paths.photoReading] in
            guard let index = await index.value, !Task.isCancelled else { return }
            self?.search = MessageSearch(store: index, account: Task { try await account.value }, photos: photos, maxChats: maxChats)
            await Self.clearOldIndex(in: kept, besides: index)
        }
    }

    /// Ends the account's work (its search's reading, waited for) and its watches: what is left
    /// goes with this session.
    func close() async {
        uploads.close()
        opening?.cancel()
        watchingEnd?.cancel()
        await search?.stop()
        search = nil
    }

    /// The app leaves the front: the sync stops, and with it the stores in the group close
    /// (before iOS suspends the app; the caller holds a background task for it).
    func enterBackground() async {
        do {
            try await account.value.pauseSync()
        } catch {
            Log.app.error("the sync did not pause: \(error, privacy: .public)")
        }
    }

    /// The app is back in front: the sync runs again and the lists catch up.
    func enterForeground() async {
        do {
            try await account.value.resumeSync()
        } catch {
            Log.app.error("the sync did not resume: \(error, privacy: .public)")
        }
    }

    private static func open(_ file: URL, key: @escaping @Sendable () async throws -> String) -> Task<LocalStore?, Never> {
        Task {
            do {
                return try await LocalStore.open(file: file, key: try await key())
            } catch {
                Log.app.error("local store: \(String(describing: error), privacy: .public)")
                return nil
            }
        }
    }

    /// The index the kept store held before it had one of its own goes, once.
    private static func clearOldIndex(in kept: Task<LocalStore?, Never>, besides index: LocalStore) async {
        guard let kept = await kept.value, kept !== index else { return }
        do {
            guard try await kept.kept(indexMovedKey) == nil else { return }
            try await kept.clearIndex()
            try await kept.keep(indexMovedKey, Data([1]))
        } catch {
            Log.app.error("local store: the old index stays: \(String(describing: error), privacy: .public)")
        }
    }

    /// Kept in the kept store once its index is gone (moved to the app's own container).
    private static let indexMovedKey = "index-moved"

    isolated deinit {
        opening?.cancel()
        watchingEnd?.cancel()
    }
}
