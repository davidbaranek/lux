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

    /// Reads each chat as far back as Settings now asks: on from where it stopped, if further.
    public func readHistory(_ history: SearchHistory) {
        Preferences.shared.searchHistory = history
        Task { await indexer.update() }
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
    /// word, the newest first, each with the chat that shows its room; the photos that match, the
    /// best first; and the first few links, files and threads with the words.
    public func search(_ text: String) async -> SearchHits {
        guard text.contains(where: { $0.isLetter || $0.isNumber }), let account = try? await account.value else { return SearchHits() }
        async let chats = account.findChats(text, limit: 20)
        async let foundPhotos = photos.search(text)
        async let found = store.search(text, limit: 60)
        async let shares = shares(text, kinds: [.links, .files, .threads], offset: 0, limit: SearchKind.links.preview + 1)
        let messages = (try? await found) ?? []
        let images = await foundPhotos
        let shown = await account.chats(ofRooms: Array(Set(messages.map(\.roomId) + images.map(\.roomId))))
        var hits = await shares
        hits.chats = await chats
        hits.messages = messages.compactMap { hit -> FoundItem? in
            guard let chat = shown[hit.roomId] else { return nil }
            return FoundItem(id: hit.eventId, chat: chat, senderName: hit.senderName, body: hit.excerpt, date: hit.date,
                             isOwn: hit.isOwn, matches: hit.matches)
        }
        hits.photos = Self.photos(images, in: shown)
        return hits
    }

    /// What chats shared lately, before any words are typed: a few of each kind, the newest first.
    public func lately() async -> SearchHits {
        await shares("", kinds: SearchKind.allCases, offset: 0, limit: SearchKind.photos.preview + 1)
    }

    /// A page of one kind for its own list: all of it, or what has the words of `text` (photos
    /// the best first, then by their look too), `limit` after `offset`.
    public func list(_ kind: SearchKind, _ text: String, offset: Int, limit: Int) async -> SearchHits {
        await shares(text, kinds: [kind], offset: offset, limit: limit)
    }

    /// `kinds`' pages, each with the chat that shows its room.
    private func shares(_ text: String, kinds: [SearchKind], offset: Int, limit: Int) async -> SearchHits {
        guard let account = try? await account.value else { return SearchHits() }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let wants = Set(kinds)
        var images: [ImageHit] = []
        if wants.contains(.photos) {
            if text.isEmpty {
                images = (try? await store.images(offset: offset, limit: limit)) ?? []
            } else {
                // ranked, not dated: a page is the best `offset + limit`, less those shown.
                images = Array(await photos.search(text, limit: offset + limit).dropFirst(offset))
            }
        }
        async let links = wants.contains(.links) ? store.links(text, offset: offset, limit: limit) : []
        async let files = wants.contains(.files) ? store.files(text, offset: offset, limit: limit) : []
        async let threads = wants.contains(.threads) ? store.threads(text, offset: offset, limit: limit) : []
        let (foundLinks, foundFiles, foundThreads) = ((try? await links) ?? [], (try? await files) ?? [], (try? await threads) ?? [])
        let rooms = images.map(\.roomId) + foundLinks.map(\.roomId) + foundFiles.map(\.roomId) + foundThreads.map(\.roomId)
        let shown = await account.chats(ofRooms: Array(Set(rooms)))
        return SearchHits(
            photos: Self.photos(images, in: shown),
            links: foundLinks.compactMap { hit in
                shown[hit.roomId].map {
                    FoundLink(eventId: hit.eventId, chat: $0, senderName: hit.senderName, url: hit.url, text: hit.text,
                              date: hit.date, isOwn: hit.isOwn)
                }
            },
            files: foundFiles.compactMap { hit in
                shown[hit.roomId].map {
                    FoundFile(id: hit.eventId, roomId: hit.roomId, chat: $0, senderName: hit.senderName, name: hit.name,
                              size: hit.size, mimetype: hit.mimetype, date: hit.date, isOwn: hit.isOwn)
                }
            },
            threads: foundThreads.compactMap { hit in
                shown[hit.roomId].map {
                    FoundThread(id: hit.root, roomId: hit.roomId, chat: $0, rootSender: hit.rootSender, rootText: hit.rootText,
                                replies: Int(hit.replies), latestSender: hit.latestSender, latestText: hit.latestText,
                                latest: hit.latest)
                }
            })
    }

    private static func photos(_ hits: [ImageHit], in shown: [String: ChatRow]) -> [FoundPhoto] {
        hits.compactMap { hit in
            shown[hit.roomId].map {
                FoundPhoto(id: hit.eventId, roomId: hit.roomId, chat: $0, senderName: hit.senderName, date: hit.date,
                           isOwn: hit.isOwn, reason: hit.reason)
            }
        }
    }
}
