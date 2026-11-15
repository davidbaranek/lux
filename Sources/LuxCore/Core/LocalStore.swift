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

    /// Opens (or makes) the store at `file` with `key`, 64 hex digits (32 bytes). A file the key
    /// does not open gives way to a new one: what it held is read again.
    public static func open(file: URL, key: String) async throws -> LocalStore {
        let store = try await CoreStore.open(path: file.path, key: key)
        #if os(iOS)
        // readable after the first unlock, so the index can grow in the background.
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                               ofItemAtPath: file.path)
        #endif
        return LocalStore(store: store)
    }

    // MARK: Writing

    /// Adds messages, or changes them (an edit keeps its event id), in one transaction.
    public func add(_ messages: [IndexedMessage]) async throws {
        guard !messages.isEmpty else { return }
        try await store.add(messages: messages.map {
            CoreStoreMessage(eventId: $0.eventId, roomId: $0.roomId, senderName: $0.senderName, body: $0.body, date: $0.date,
                         isOwn: $0.isOwn)
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
        try await store.setChat(chat: CoreStoreChat(roomId: roomId, newest: chat.newest, complete: chat.complete))
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
            }
            return ImageHit(eventId: hit.eventId, roomId: hit.roomId, senderName: hit.senderName, date: hit.date,
                            isOwn: hit.isOwn, reason: reason)
        }
    }

    // MARK: Reading

    /// How far each chat is indexed.
    public func chats() async throws -> [String: IndexedChat] {
        let chats = try await store.chats()
        return Dictionary(chats.map { ($0.roomId, IndexedChat(newest: $0.newest, complete: $0.complete)) },
                          uniquingKeysWith: { first, _ in first })
    }

    public func messageCount() async throws -> Int {
        Int(clamping: try await store.messageCount())
    }

    /// The messages with every word of `text`, each word matched by its start, without case or
    /// accents; the newest first. `roomId` keeps one chat's.
    public func search(_ text: String, in roomId: String? = nil, limit: Int = 50) async throws -> [IndexHit] {
        let hits = try await store.search(text: text, roomId: roomId, limit: UInt32(clamping: limit))
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
