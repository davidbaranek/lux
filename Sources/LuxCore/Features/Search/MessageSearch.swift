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
    /// What messages mean, read with the photos' model while semantic search is on.
    private let meaning: MessageMeaning

    private let store: LocalStore
    private let indexer: SearchIndexer
    private let account: Task<any SearchSourcePort, any Error>
    private var following: Task<Void, Never>?
    /// What follows the index's progress: it ends with the search.
    private var listening: Task<Void, Never>?
    /// The index's, the photos' and the meaning's reading: it ends with the search.
    private let work = ForegroundJobs()

    /// Search over `store`, filled from `account`; photos are downloaded to `photos` to be read.
    init(store: LocalStore, account: Task<any SearchSourcePort, any Error>, photos directory: URL, maxChats: Int? = nil) {
        self.store = store
        self.account = account
        let (reports, report) = AsyncStream<SearchIndexer.Progress>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let indexer = SearchIndexer(store: store, account: Task { try await account.value }, maxChats: maxChats) { report.yield($0) }
        self.indexer = indexer
        let photos = PhotoSearch(store: store, account: Task { try await account.value }, directory: directory)
        self.photos = photos
        let meaning = MessageMeaning(store: store)
        self.meaning = meaning
        let work = self.work
        photos.onModel = { model in
            work.start("meaning") { lease in
                await meaning.use(model)
                if model != nil, await Saving.shared.reason == nil { await meaning.read(limit: nil, lease: lease) }
            }
        }
        listening = Task { [weak self] in
            for await progress in reports {
                self?.progress = progress
                self?.progressChanges.send()
                // a pass ended: the photos and messages it brought are read.
                if !progress.isIndexing {
                    photos.update()
                    if Saving.shared.reason == nil {
                        work.start("meaning") { lease in await meaning.read(limit: nil, lease: lease) }
                    }
                }
            }
        }
        Self.update(indexer, in: work)
        // a chat changed (a new message), in any place, not only the one on screen: the index
        // reads what is new, at most every few seconds.
        following = Task {
            guard let changes = await bestEffort("search: follow the chats", { try await account.value.chatChanges() }) else { return }
            let throttle = Throttle(interval: .seconds(3))
            for await _ in changes {
                throttle.schedule { await MainActor.run { Self.update(indexer, in: work) } }
            }
        }
        // back in front: what came meanwhile is read, and the photos and messages after it.
        returning = ForegroundWork.shared.onReturn { Self.update(indexer, in: work) }
    }

    isolated deinit {
        following?.cancel()
        listening?.cancel()
    }

    private var returning: AnyObject?

    /// Brings the index up to date, as foreground work.
    private static func update(_ indexer: SearchIndexer, in work: ForegroundJobs) {
        work.start("index") { lease in await indexer.update(lease: lease) }
    }

    func stop() async {
        following?.cancel()
        listening?.cancel()
        await indexer.stop()
        await work.end()
        await photos.stop()
        await meaning.stop()
    }

    /// How many messages mean something, and how many were read, for Settings.
    public func meaningProgress() async -> (total: Int, read: Int) {
        await meaning.progress()
    }

    /// Reads each chat as far back as Settings now asks: on from where it stopped, if further.
    public func readHistory(_ history: SearchHistory) {
        Preferences.shared.searchHistory = history
        Self.update(indexer, in: work)
    }

    /// The index for Settings: "12 340 messages · complete", or how far it is reading.
    public func summary() async throws -> String {
        let messages = try await store.messageCount()
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
        guard text.contains(where: { $0.isLetter || $0.isNumber }),
              let account = await bestEffort("search", { try await account.value }) else { return SearchHits() }
        async let chats = account.findChats(text, limit: 20)
        // the words' embedding once: photos by their look, messages by their meaning.
        let embedding = await photos.embedding(of: text)
        let meant = await meaning.query(embedding)
        let minSimilarity = await meaning.minSimilarity ?? 1
        async let foundPhotos = photos.search(text, embedding: embedding)
        async let found = bestEffort("search: messages") {
            try await store.search(text, embedding: meant, minSimilarity: minSimilarity, limit: 60)
        } ?? []
        async let shares = shares(text, kinds: [.links, .files, .threads], offset: 0, limit: SearchKind.links.preview + 1)
        let messages = await found
        let images = await foundPhotos
        let shown = await account.chats(ofRooms: Array(Set(messages.map(\.roomId) + images.map(\.roomId))))
        var hits = await shares
        hits.chats = await chats
        hits.messages = messages.compactMap { hit -> FoundItem? in
            guard let chat = shown[hit.roomId] else { return nil }
            return FoundItem(id: hit.eventId, roomId: hit.roomId, chat: chat, senderName: hit.senderName, body: hit.excerpt, date: hit.date,
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
        guard let account = await bestEffort("search: shared", { try await account.value }) else { return SearchHits() }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let wants = Set(kinds)
        var images: [ImageHit] = []
        if wants.contains(.photos) {
            if text.isEmpty {
                images = await bestEffort("search: photos") { try await store.images(offset: offset, limit: limit) } ?? []
            } else {
                // ranked, not dated: a page is the best `offset + limit`, less those shown.
                images = Array(await photos.search(text, limit: offset + limit).dropFirst(offset))
            }
        }
        async let links = wants.contains(.links) ? bestEffort("search: links") { try await store.links(text, offset: offset, limit: limit) } ?? [] : []
        async let files = wants.contains(.files) ? bestEffort("search: files") { try await store.files(text, offset: offset, limit: limit) } ?? [] : []
        async let threads = wants.contains(.threads)
            ? bestEffort("search: threads") { try await store.threads(text, offset: offset, limit: limit) } ?? [] : []
        let (foundLinks, foundFiles, foundThreads) = await (links, files, threads)
        let rooms = images.map(\.roomId) + foundLinks.map(\.roomId) + foundFiles.map(\.roomId) + foundThreads.map(\.roomId)
        let shown = await account.chats(ofRooms: Array(Set(rooms)))
        return SearchHits(
            photos: Self.photos(images, in: shown),
            links: foundLinks.compactMap { hit in
                shown[hit.roomId].map {
                    FoundLink(eventId: hit.eventId, roomId: hit.roomId, chat: $0, senderName: hit.senderName, url: hit.url, text: hit.text,
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
