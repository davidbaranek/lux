import Foundation

/// The chats and their history, as the search index reads them. What `SearchIndexer` needs of an
/// account; the Rust core's account adapts it (`RustAccount.swift`, `RustTimeline.swift`).
protocol IndexSourcePort: Sendable {
    /// The account's chats, as the list shows them.
    func chats() async -> [ChatRow]
    /// A page of `roomId`'s history back to `since`: from its newest message, or from `from` (where
    /// the last page ended), at most `maxPages` of the server's pages.
    func indexHistory(roomId: String, since: Date, from: String?, maxPages: Int) async throws -> IndexHistoryPage
}

/// A shared photo or file, downloaded. What `PhotoIndexer` needs of an account to read photos;
/// the Rust core's account adapts it (`RustChatDetails.swift`).
protocol MediaSourcePort: Sendable {
    /// Downloads the media of `eventId` in `roomId` into `directory`; the file.
    func sharedFile(roomId: String, eventId: String, directory: URL) async throws -> URL
}

/// Reads what a photo shows: its words and, with a model, how it looks. What `PhotoIndexer` needs
/// to read photos; `PhotoReader` (Vision, and the photo search model) is the app's.
protocol PhotoReading: Sendable {
    /// Who reads, kept with what was read: a reader that reads more (the model arrived) or
    /// better (a newer version) reads every photo again.
    var name: String { get }
    /// What `file` shows: its words, one line each in reading order, and its embedding.
    func read(_ file: URL, lease: ForegroundLease) async throws -> (words: String, embedding: [Float]?)
    /// The reading ended, and none follows it: what the reader keeps for the next photo (the
    /// model's image encoder) goes until photos come to be read again.
    func rest() async
}

/// Finding chats and the chats that show rooms, and following changes. What `MessageSearch`
/// needs of an account besides what its indexers do.
protocol ChatLookupPort: Sendable {
    /// The chats whose name has every word of `query`, the most recent first, at most `limit`.
    func findChats(_ query: String, limit: Int) async -> [ChatRow]
    /// The chat of the list that shows each room: its own, or the merged chat it is in.
    func chats(ofRooms rooms: [String]) async -> [String: ChatRow]
    /// Tells of each change to a chat (a new message), in any place, until the stream ends.
    func chatChanges() -> AsyncStream<Void>
}

/// All that search needs of an account.
typealias SearchSourcePort = IndexSourcePort & MediaSourcePort & ChatLookupPort

/// The Rust core's account is search's and the chat list's adapter.
extension RustAccount: IndexSourcePort, MediaSourcePort, ChatLookupPort, ChatListPort {}
