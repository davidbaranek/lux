import Foundation
import LuxBindings

/// The account's own store on this device, kept by the Rust core (`lux-store`): one SQLite
/// database encrypted with SQLCipher (the key in the Keychain), holding the message search index
/// and a few kept values (the last chat list, drawn at launch). One file per account. A word
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
                     matches: hit.matches.map { NSRange(location: Int($0.start), length: Int($0.length)) },
                     date: hit.date, isOwn: hit.isOwn)
        }
    }
}
