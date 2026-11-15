import Foundation

/// The account's search: chats by name (found by the core), messages from the encrypted index on
/// this device, which `SearchIndexer` keeps filling as messages arrive, and photos when the user
/// turned photo search on (`photos`).
@MainActor
public final class MessageSearch {
    public private(set) var progress: SearchIndexer.Progress?
    /// How far the index is, for the UI (the search screen's footer, the loading bubble).
    public let progressChanges = Broadcast()

    /// Search in photos, off until the user turns it on.
    public let photos: PhotoSearch

    private let store: LocalStore
    private let indexer: SearchIndexer
    private let account: Task<RustAccount, any Error>
    private var following: Task<Void, Never>?

    init(store: LocalStore, account: Task<RustAccount, any Error>, maxChats: Int? = nil) {
        self.store = store
        self.account = account
        let (reports, report) = AsyncStream<SearchIndexer.Progress>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let indexer = SearchIndexer(store: store, account: account, maxChats: maxChats) { report.yield($0) }
        self.indexer = indexer
        let photos = PhotoSearch(store: store, account: account,
                                 directory: FileManager.default.temporaryDirectory.appending(path: "photo-search"))
        self.photos = photos
        Task { [weak self] in
            for await progress in reports {
                self?.progress = progress
                self?.progressChanges.send()
                // a pass ended: the photos it brought are read.
                if !progress.isIndexing { photos.update() }
            }
        }
        Task { await indexer.update() }
        // a chat changed (a new message), in any place, not only the one on screen: the index
        // reads what is new, at most every few seconds.
        following = Task {
            guard let changes = try? await account.value.chatChanges() else { return }
            let throttle = Throttle(interval: .seconds(3))
            for await _ in changes {
                throttle.schedule { await indexer.update() }
            }
        }
    }

    isolated deinit {
        following?.cancel()
    }

    func stop() async {
        following?.cancel()
        await indexer.stop()
        await photos.stop()
    }

    /// The index for Settings: "12 340 messages · complete", or how far it is reading.
    public func summary() async -> String {
        let messages = (try? await store.messageCount()) ?? 0
        let count = messages.formatted(.number)
        if let note = progress.flatMap({ $0.isIndexing ? $0 : nil }), note.total > 0 {
            return String(localized: "\(count) messages · reading \(note.chats) of \(note.total) chats")
        }
        return String(localized: "\(count) messages · complete")
    }

    /// Chats whose name has every word (without case or accents), then the messages with every
    /// word, the newest first, each with the chat that shows its room; and the photos that match,
    /// the best first, when photo search is on.
    public func search(_ text: String) async -> SearchHits {
        guard text.contains(where: { $0.isLetter || $0.isNumber }), let account = try? await account.value else { return SearchHits() }
        async let chats = account.findChats(text, limit: 20)
        let found = (try? await store.search(text, limit: 60)) ?? []
        let images = await photos.search(text)
        let shown = await account.chats(ofRooms: Array(Set(found.map(\.roomId) + images.map(\.roomId))))
        let messages = found.compactMap { hit -> FoundItem? in
            guard let chat = shown[hit.roomId] else { return nil }
            return FoundItem(id: hit.eventId, chat: chat, senderName: hit.senderName, body: hit.excerpt, date: hit.date,
                             isOwn: hit.isOwn, matches: hit.matches)
        }
        let photos = images.compactMap { hit -> FoundPhoto? in
            guard let chat = shown[hit.roomId] else { return nil }
            return FoundPhoto(id: hit.eventId, roomId: hit.roomId, chat: chat, senderName: hit.senderName, date: hit.date,
                              isOwn: hit.isOwn, reason: hit.reason)
        }
        return SearchHits(chats: await chats, messages: messages, photos: photos)
    }
}
