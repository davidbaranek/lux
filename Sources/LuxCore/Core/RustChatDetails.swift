import Foundation
import LuxBindings

/// A chat's details in the Rust core: its rooms' state, members, shared history, and what the
/// details screen changes, in the app's types. The generated types stay in `Core/`.
extension RustAccount {
    func chatInfo(chatId: String) async throws -> ChatInfo {
        let details = try await worded { try await account.chatDetails(chatId: chatId) }
        return ChatInfo(rooms: details.rooms.map(RoomInfo.init), notifications: details.notifications.map(NotificationSetting.init))
    }

    func members(roomId: String) async throws -> MemberList {
        MemberList(try await worded { try await account.roomMembers(roomId: roomId) })
    }

    /// What the chat shared, of `kind`; with a `query`, only what holds its words.
    func sharedHistory(chatId: String, kind: SharedKind, query: String? = nil) async throws -> SharedHistory {
        let kind: CoreSharedKind = switch kind {
        case .media: .media
        case .files: .files
        case .links: .links
        }
        return SharedHistory(try await worded { try await account.sharedHistory(chatId: chatId, kind: kind, query: query) })
    }

    func setNotifications(chatId: String, _ setting: NotificationSetting) async throws {
        let mode: CoreNotificationMode = switch setting {
        case .default: .default
        case .all: .all
        case .mentions: .mentions
        case .off: .off
        }
        try await worded { try await account.setChatNotifications(chatId: chatId, mode: mode) }
    }

    func change(chatId: String, _ change: ChatChange) async throws {
        try await worded { try await account.changeChat(chatId: chatId, change: CoreChatChange(change)) }
    }

    func renameRoom(roomId: String, to name: String) async throws {
        try await worded { try await account.renameRoom(roomId: roomId, name: name) }
    }

    func setTopic(roomId: String, _ topic: String) async throws {
        try await worded { try await account.setRoomTopic(roomId: roomId, topic: topic) }
    }

    /// Uploads a JPEG as the room's picture.
    func setRoomPicture(roomId: String, jpeg: Data) async throws {
        try await worded { try await account.setRoomPicture(roomId: roomId, data: jpeg, format: .jpeg) }
    }

    func removeRoomPicture(roomId: String) async throws {
        try await worded { try await account.removeRoomPicture(roomId: roomId) }
    }

    /// One page of a room's Matrix threads from `from` (the latest active first when nil), and
    /// where the next starts.
    func threads(roomId: String, from: String?) async throws -> (threads: [ListedThread], next: String?) {
        let page = try await worded { try await account.roomThreads(roomId: roomId, from: from) }
        let threads = page.threads.map { listed in
            ListedThread(thread: MatrixThread(roomId: roomId, rootEventId: listed.rootEventId), senderName: listed.sender.name,
                         senderAvatar: listed.sender.avatar.map { .person(url: $0) }, text: PreviewLine.body(listed.kind),
                         date: listed.date, summary: MessageItem.ThreadSummary(listed.summary))
        }
        return (threads, page.next)
    }

    func leave(chatId: String) async throws {
        try await worded { try await account.leaveChat(chatId: chatId) }
    }

    /// A shared photo's, video's or file's original on this device, downloaded once into `directory`.
    func sharedFile(_ item: SharedItem, directory: URL) async throws -> URL {
        try await sharedFile(roomId: item.roomId, eventId: item.eventId, directory: directory)
    }

    /// The original of the photo, video or file a message's event sent (no timeline need hold
    /// it: chat details, photo search), downloaded once into `directory`.
    func sharedFile(roomId: String, eventId: String, directory: URL) async throws -> URL {
        // the demo's events are its messages.
        if let demo { return try demo.mediaFile(roomId: roomId, messageId: eventId, directory: directory) }
        return URL(fileURLWithPath: try await worded {
            try await account.sharedFile(roomId: roomId, eventId: eventId, folder: directory.path)
        })
    }
}

/// A room's members, loaded once, found by name as the user types.
final class MemberList: Sendable {
    private let list: CoreMemberList
    init(_ list: CoreMemberList) { self.list = list }

    var count: Int { Int(clamping: list.count()) }

    func find(_ query: String, limit: Int) -> [ChatMember] {
        list.find(query: query, limit: UInt32(clamping: limit)).map(ChatMember.init)
    }
}

/// What a chat shared, of one kind, read back the newest first.
final class SharedHistory: Sendable {
    private let history: CoreSharedHistory
    init(_ history: CoreSharedHistory) { self.history = history }

    func next(_ count: Int) async throws -> [SharedItem] {
        let items = try await worded { try await history.next(count: UInt32(clamping: count)) }
        return items.compactMap(SharedItem.init)
    }

    func isAtStart() async -> Bool { await history.isAtStart() }
}

private extension RoomInfo {
    init(_ room: CoreRoomDetails) {
        self.init(id: room.id, network: room.network, name: room.name, topic: room.topic,
                  avatar: room.avatar.map { .room(id: room.id, version: $0) }, address: room.address,
                  isEncrypted: room.isEncrypted, isDirect: room.isDirect, joinedMembers: Int(clamping: room.joinedMembers),
                  notifications: NotificationSetting(room.notifications), canRename: room.canRename,
                  canChangeTopic: room.canChangeTopic, canChangeAvatar: room.canChangeAvatar)
    }
}

private extension NotificationSetting {
    init(_ mode: CoreNotificationMode) {
        self = switch mode {
        case .default: .default
        case .all: .all
        case .mentions: .mentions
        case .off: .off
        }
    }
}

private extension ChatMember {
    init(_ member: CoreMember) {
        let role: MemberRole = switch member.role {
        case .creator: .creator
        case .admin: .admin
        case .moderator: .moderator
        case .member: .member
        }
        self.init(id: member.userId, name: member.name, avatar: member.avatar.map { .person(url: $0) }, role: role,
                  isOwn: member.isOwn)
    }
}

private extension SharedItem {
    /// Nil for a link that is no URL.
    init?(_ item: CoreSharedItem) {
        let photo = { (picture: CorePicture) in
            MessageItem.Photo(ref: .shared(roomId: item.roomId, eventId: item.eventId, name: picture.source),
                              width: Int(picture.width), height: Int(picture.height))
        }
        let content: Content
        var id = item.eventId
        switch item.content {
        case .photo(let picture): content = .photo(photo(picture))
        case .video(let poster, let seconds): content = .video(poster: poster.map(photo), duration: seconds)
        case .file(let name, let size, let mimetype): content = .file(name: name, size: size.map { Int(clamping: $0) }, mimetype: mimetype)
        case .link(let address, let text):
            guard let url = URL(string: address) else { return nil }
            content = .link(url, text: text)
            id += "|" + address
        }
        self.init(id: id, eventId: item.eventId, roomId: item.roomId, senderName: item.senderName, date: item.date, content: content)
    }
}
