import Foundation
import LuxBindings

/// The account's own store on this device, kept by the Rust core (`lux-store`): one SQLite
/// database encrypted with SQLCipher (the key in the Keychain), holding the message search index,
/// the photos photo search reads (their words and embeddings), and a few kept values (the last
/// chat list, drawn at launch). One file per account. A word
/// matches by its start and without accents ("zit" finds "Zítra"); the newest messages first.
/// The core runs each call on the store's own thread, so none blocks the caller's.
public final class LocalStore: Sendable {
    /// Shared with the Rust core's account, which keeps its chat list in it.
    let store: CoreStore

    private init(store: CoreStore) { self.store = store }

    /// Opens (or makes) the store at `file` with `key`, 64 hex digits (32 bytes), as the one
    /// process that owns it (the app): a file the key does not open, or a damaged one, gives way
    /// to a new one, and what it held is read again.
    public static func openOrReplace(file: URL, key: String) async throws -> LocalStore {
        protect(file, try await CoreStore.openOrReplace(path: file.path, key: key))
    }

    /// Opens (or makes) the store at `file` with `key` beside the process that owns it (the share
    /// extension beside the app): a file it cannot use throws and stays, for the app to replace.
    /// Removing a file another process has open would damage what that one writes.
    public static func open(file: URL, key: String) async throws -> LocalStore {
        protect(file, try await CoreStore.open(path: file.path, key: key))
    }

    private static func protect(_ file: URL, _ store: CoreStore) -> LocalStore {
        #if os(iOS)
        // readable after the first unlock, so the index can grow in the background.
        bestEffort("local store: readable after the first unlock") {
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                                  ofItemAtPath: file.path)
        }
        #endif
        return LocalStore(store: store)
    }

    /// Closes the store for good, after the calls made before; later calls fail. Awaited as the
    /// account's session ends: the connection closes on the store's thread while nothing waits,
    /// where the last handle let go without it would wait on the thread that lets it go (the
    /// main one, for a session).
    public func close() async {
        await store.close()
    }

    /// Returns when the store has made a new, empty file in place of one a call found damaged
    /// (a page that fails its check, after a crash in a write): what it held is to be read again.
    /// Throws once the store has closed.
    func replaced() async throws {
        try await store.replaced()
    }

    // MARK: Writing

    /// Adds messages, or changes them (an edit keeps its event id), in one transaction.
    public func add(_ messages: [IndexedMessage]) async throws {
        guard !messages.isEmpty else { return }
        try await store.add(messages: messages.map {
            CoreStoreMessage(eventId: $0.eventId, roomId: $0.roomId, senderName: $0.senderName, body: $0.body, links: $0.links,
                             thread: $0.thread, date: $0.date, isOwn: $0.isOwn)
        })
    }

    /// Adds files from a chat's history, or changes their names.
    public func addFiles(_ files: [IndexedFile]) async throws {
        guard !files.isEmpty else { return }
        try await store.addFiles(files: files.map {
            CoreStoreFile(eventId: $0.eventId, roomId: $0.roomId, senderName: $0.senderName, name: $0.name, size: $0.size,
                          mimetype: $0.mimetype, date: $0.date, isOwn: $0.isOwn)
        })
    }

    /// Removes messages deleted in their chat: search no longer finds their text.
    public func remove(_ eventIds: [String]) async throws {
        guard !eventIds.isEmpty else { return }
        try await store.remove(eventIds: eventIds)
    }

    /// Forgets a chat's messages: up to `until` (the chat was deleted then), or all of them and
    /// how far the index read it (nil: the chat is gone from the account's list).
    public func forgetChat(_ roomId: String, until: Date? = nil) async throws {
        try await store.forgetChat(roomId: roomId, until: until)
    }

    public func setChat(_ roomId: String, _ chat: IndexedChat) async throws {
        try await store.setChat(chat: CoreStoreChat(roomId: roomId, newest: chat.newest, complete: chat.complete,
                                                    oldest: chat.oldest, older: chat.older))
    }

    // MARK: Photos

    /// Adds photos from a chat's history, or changes their captions.
    public func addImages(_ images: [IndexedImage]) async throws {
        guard !images.isEmpty else { return }
        try await store.addImages(images: images.map {
            CoreStoreImage(eventId: $0.eventId, roomId: $0.roomId, senderName: $0.senderName, caption: $0.caption,
                           date: $0.date, isOwn: $0.isOwn)
        })
    }

    /// The photos `reader` has not read yet, the newest first: each one's event and room.
    public func imagesToRead(by reader: String, limit: Int) async throws -> [(eventId: String, roomId: String)] {
        try await store.imagesToRead(reader: reader, limit: UInt32(clamping: limit)).map { ($0.eventId, $0.roomId) }
    }

    /// Keeps what was read in photos.
    public func setImagesRead(_ reads: [PhotoRead]) async throws {
        guard !reads.isEmpty else { return }
        try await store.setImagesRead(reads: reads.map {
            CoreImageRead(eventId: $0.eventId, reader: $0.reader, words: $0.words, embedding: $0.embedding)
        })
    }

    /// A photo could not be read (not loaded, not decrypted); after a few tries it is left.
    public func imageUnread(_ eventId: String) async throws {
        try await store.imageUnread(eventId: eventId)
    }

    /// Asks again for every photo that could not be read (another model, the photo downloads now).
    public func retryUnreadImages() async throws {
        try await store.retryUnreadImages()
    }

    /// Forgets every photo's embedding (search by how photos look was turned off); their words
    /// stay, as read by `reader` (the one without the model).
    public func forgetImageEmbeddings(reader: String) async throws {
        try await store.forgetImageEmbeddings(reader: reader)
    }

    /// How many photos the index has, how many `reader` has read, how many had their words read
    /// and how many have an embedding.
    public func imageCounts(reader: String) async throws -> (total: Int, read: Int, withWords: Int, withEmbedding: Int) {
        let counts = try await store.imageCounts(reader: reader)
        return (Int(clamping: counts.total), Int(clamping: counts.read), Int(clamping: counts.withWords),
                Int(clamping: counts.withEmbedding))
    }

    /// The photos that match `text`: by their caption and the words in them, the messages sent
    /// near them, and how they look (`embedding`, the words' in the photos' space); the best first.
    /// `roomId` keeps one room's.
    public func searchImages(_ text: String, embedding: [Float]?, minSimilarity: Float, in roomId: String? = nil,
                             limit: Int = 30) async throws -> [ImageHit] {
        let hits = try await store.searchImages(search: CoreImageSearch(
            text: text, embedding: embedding, minSimilarity: minSimilarity, roomId: roomId, limit: UInt32(clamping: limit)))
        return hits.map { hit in
            let reason: PhotoReason = switch hit.reason {
            case .words(let excerpt, let matches): .words(excerpt, matches: matches.map(\.range))
            case .nearby(let excerpt, let matches): .nearby(excerpt, matches: matches.map(\.range))
            case .looks: .looks
            case .listed: .listed
            }
            return ImageHit(eventId: hit.eventId, roomId: hit.roomId, senderName: hit.senderName, date: hit.date,
                            isOwn: hit.isOwn, reason: reason)
        }
    }

    // MARK: Meaning

    /// Messages whose meaning is not read yet, the newest first, at least `minChars` long, each
    /// with the messages before it in its thread or chat.
    func messagesToEmbed(minChars: Int, limit: Int) async throws -> [MessageToEmbed] {
        try await store.messagesToEmbed(minChars: UInt32(clamping: minChars), limit: UInt32(clamping: limit)).map {
            MessageToEmbed(eventId: $0.eventId, senderName: $0.senderName, body: $0.body,
                           context: $0.context.map { MessageToEmbed.Line(senderName: $0.senderName, body: $0.body) })
        }
    }

    /// Keeps what `embedder` read of messages' meaning: an embedding each, or nil for one with too
    /// little to mean.
    func setMessageEmbeddings(_ reads: [(eventId: String, embedding: [Float]?)], by embedder: String) async throws {
        guard !reads.isEmpty else { return }
        try await store.setMessageEmbeddings(embeddings: reads.map {
            CoreMessageEmbedding(eventId: $0.eventId, embedder: embedder, embedding: $0.embedding)
        })
    }

    /// Forgets the messages' embeddings but `keep`'s (nil: all of them).
    func forgetMessageEmbeddings(keep: String?) async throws {
        try await store.forgetMessageEmbeddings(keep: keep)
    }

    /// How many messages are long enough to mean something, and how many were read.
    func embeddingCounts(minChars: Int) async throws -> (total: Int, read: Int) {
        let counts = try await store.embeddingCounts(minChars: UInt32(clamping: minChars))
        return (Int(clamping: counts.total), Int(clamping: counts.read))
    }

    /// Forgets the whole search index, keeping the kept values.
    func clearIndex() async throws {
        try await store.clearIndex()
    }

    /// A value kept with the index (encrypted with it).
    func kept(_ key: String) async throws -> Data? {
        try await store.kept(key: key)
    }

    func keep(_ key: String, _ value: Data) async throws {
        try await store.keep(key: key, value: value)
    }

    // MARK: Lists

    /// The photos, the newest first: `limit` after `offset`; `roomId` keeps one room's.
    func images(in roomId: String? = nil, offset: Int, limit: Int) async throws -> [ImageHit] {
        try await store.images(browse: browse("", roomId, offset, limit)).map {
            ImageHit(eventId: $0.eventId, roomId: $0.roomId, senderName: $0.senderName, date: $0.date, isOwn: $0.isOwn,
                     reason: .listed)
        }
    }

    /// The web addresses messages sent, the newest first: all, or those of the messages with
    /// every word of `text`.
    func links(_ text: String, in roomId: String? = nil, offset: Int, limit: Int) async throws -> [CoreLinkHit] {
        try await store.links(browse: browse(text, roomId, offset, limit))
    }

    /// The files, the newest first: all, or those whose name has every word of `text`.
    func files(_ text: String, in roomId: String? = nil, offset: Int, limit: Int) async throws -> [CoreFileHit] {
        try await store.files(browse: browse(text, roomId, offset, limit))
    }

    /// The threads by their newest reply: all, or those whose root or a reply has every word.
    func threads(_ text: String, in roomId: String? = nil, offset: Int, limit: Int) async throws -> [CoreThreadHit] {
        try await store.threads(browse: browse(text, roomId, offset, limit))
    }

    private func browse(_ text: String, _ roomId: String?, _ offset: Int, _ limit: Int) -> CoreBrowse {
        CoreBrowse(text: text, roomId: roomId, limit: UInt32(clamping: limit), offset: UInt32(clamping: offset))
    }

    // MARK: Reading

    /// How far each chat is indexed.
    public func chats() async throws -> [String: IndexedChat] {
        let chats = try await store.chats()
        return Dictionary(chats.map {
            ($0.roomId, IndexedChat(newest: $0.newest, complete: $0.complete, oldest: $0.oldest, older: $0.older))
        },
                          uniquingKeysWith: { first, _ in first })
    }

    public func messageCount() async throws -> Int {
        Int(clamping: try await store.messageCount())
    }

    /// The messages with every word of `text`, each word matched by its start, without case or
    /// accents, the newest first; with `embedding` (the words' meaning) also those whose meaning
    /// is like it, at least `minSimilarity`, merged. `roomId` keeps one chat's.
    public func search(_ text: String, embedding: [Float]? = nil, minSimilarity: Float = 1, in roomId: String? = nil,
                       limit: Int = 50) async throws -> [IndexHit] {
        let hits = try await store.search(text: text, embedding: embedding, minSimilarity: minSimilarity, roomId: roomId,
                                          limit: UInt32(clamping: limit))
        return hits.map { hit in
            IndexHit(eventId: hit.eventId, roomId: hit.roomId, senderName: hit.senderName, excerpt: hit.excerpt,
                     matches: hit.matches.map(\.range),
                     date: hit.date, isOwn: hit.isOwn)
        }
    }
}

private extension CoreStoreMatch {
    var range: NSRange { NSRange(location: Int(start), length: Int(length)) }
}
