import Foundation

/// Finding people and chats and starting a conversation. What `NewConversationModel` needs of an
/// account; the Rust core's account adapts it (`RustAccountActions.swift`, `RustAccount.swift`).
protocol ConversationsPort: Sendable {
    /// The chats whose name has every word of `query`, the most recent first, at most `limit`.
    func findChats(_ query: String, limit: Int) async -> [ChatRow]
    /// The people the server's directory finds for `query`.
    func contacts(query: String) async throws -> ContactListing
    /// Opens (or finds) the direct chat with `contact`; its room's id.
    func startConversation(with contact: Contact) async throws -> String
}
