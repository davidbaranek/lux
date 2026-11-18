import Foundation

/// A chat list as the core presents it: its rows and places as they change, and what the user
/// does to them. `ChatListModel` needs this and nothing else of a list; the Rust core's list
/// adapts it (`RustChatList.swift`), opened by the session (`Session.openChatList`).
protocol ChatListView: Sendable {
    /// The list's batches and failed intents as they come.
    var events: AsyncStream<ChatListEvent> { get }
    /// Shows `place`; returns this selection's number, which the batches that show it carry
    /// (`ChatListBatch.selection`). Each is greater than the one before; 0 is the place the list
    /// opened at.
    func select(_ place: Place) -> UInt64
    func setFilter(_ filter: ChatFilter?)
    func setOrder(_ order: ChatOrder)
    func setDrafts(_ drafts: Set<String>)
    func refresh()
    func change(_ chatId: String, _ change: ChatChange)
    func answer(request roomId: String, accept: Bool)
    func makeLabel(named name: String, with chatId: String?)
    func removeLabel(id: String)
    func setChat(_ chatId: String, inLabel id: String, _ included: Bool)
    func setReminder(_ chatId: String, at date: Date?)
    func unsave(roomId: String, eventId: String)
    func cancelScheduled(id: String)
    func merge(_ chatIds: [String], name: String, defaultRoom: String)
    func unmerge(_ chatId: String)
    func reorder(_ places: [Place])
    func setHidden(_ place: Place, _ hidden: Bool)
    func showAllPlaces()
    func setTheme(_ place: Place, _ theme: PlaceTheme?)
    func setDefaultTheme(_ theme: PlaceTheme)
    func setInbox(_ place: Place, _ rule: InboxRule)
    func setNotifications(_ chatId: String, _ setting: NotificationSetting)
    func setNotifications(_ place: Place, _ setting: NotificationSetting)
}

/// What a chat list sends, in order.
enum ChatListEvent: Sendable {
    case batch(ChatListBatch)
    case failed(AccountFailure)
}

/// What the chat list needs of an account besides its list: the chats that show rooms,
/// fetching a chat ahead, and making a group. The Rust core's account adapts it.
protocol ChatListPort: Sendable {
    func chats(ofRooms rooms: [String]) async -> [String: ChatRow]
    /// Loads a chat's (or its Matrix thread's) newest messages ahead of its opening.
    func prefetch(roomId: String, thread: String?) async throws
    /// Makes a group named `name`; its room's id.
    func createRoom(name: String) async throws -> String
}
