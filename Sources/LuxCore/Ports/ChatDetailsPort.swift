import Foundation

/// A chat's details and what can be done with it: its rooms, its settings, its members, what it
/// shared and its threads. What the chat details models need of an account; the Rust core's
/// account adapts it (`RustChatDetails.swift`).
protocol ChatDetailsPort: Sendable {
    func chatInfo(chatId: String) async throws -> ChatInfo
    /// A room's members, loaded once, to find by name.
    func members(roomId: String) async throws -> any MemberList
    /// What the chat shared, of `kind`; with a `query`, only what holds its words.
    func sharedHistory(chatId: String, kind: SharedKind, query: String?) async throws -> any SharedHistory
    /// Downloads a shared photo or file into `directory`; the file.
    func sharedFile(_ item: SharedItem, directory: URL) async throws -> URL
    /// A room's threads, the newest first, from `from` (where the last page ended).
    func threads(roomId: String, from: String?) async throws -> (threads: [ListedThread], next: String?)

    func setNotifications(chatId: String, _ setting: NotificationSetting) async throws
    func change(chatId: String, _ change: ChatChange) async throws
    func renameRoom(roomId: String, to name: String) async throws
    func setTopic(roomId: String, _ topic: String) async throws
    func setRoomPicture(roomId: String, jpeg: Data) async throws
    func removeRoomPicture(roomId: String) async throws
    /// Leaves the chat (each room of a merged one).
    func leave(chatId: String) async throws
}

/// A room's members, loaded once, found by name as the user types.
protocol MemberList: Sendable {
    var count: Int { get }
    func find(_ query: String, limit: Int) -> [ChatMember]
}

/// What a chat shared, of one kind, read back the newest first.
protocol SharedHistory: Sendable {
    func next(_ count: Int) async throws -> [SharedItem]
    func isAtStart() async -> Bool
}
