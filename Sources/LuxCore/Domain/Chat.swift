import Foundation

/// A chat the account is invited to: accepting joins it, declining refuses it.
public struct ChatRequest: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var avatar: ImageRef?
    /// Who invited the account; "" when the invite does not say.
    public var inviterName: String
    public var isDirect: Bool
    public init(id: String, name: String, avatar: ImageRef?, inviterName: String, isDirect: Bool) {
        self.id = id; self.name = name; self.avatar = avatar; self.inviterName = inviterName; self.isDirect = isDirect
    }
}

extension ChatRequest {
    /// The request as a chat-list row: who invited, in place of a message.
    public var row: ChatRow {
        ChatRow(id: id, name: name, preview: inviterName.isEmpty ? String(localized: "Invited you")
                    : isDirect ? String(localized: "Wants to chat") : String(localized: "\(inviterName) invited you"),
                date: nil, isMarkedUnread: true, avatar: avatar, isGroup: !isDirect)
    }
}

/// A private group of chats the user names (Work, Family), kept with the account.
public struct ChatLabel: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var rooms: Set<String>
    public init(id: String, name: String, rooms: Set<String>) { self.id = id; self.name = name; self.rooms = rooms }
}

/// What a chat's menu does to it.
public enum ChatChange: String, Sendable, CaseIterable {
    case read, unread, mute, unmute, lowPriority, inbox, archive, unarchive, delete, pin, unpin
}

/// Which list a chat is in.
public enum ChatFolder: String, Sendable, Hashable {
    case inbox, lowPriority, archive
}

/// A run of the list under one heading: a space's own chats, or one of its spaces' (as Discord
/// lists a server's channels by category). A place that is not a space has one, with no title.
public struct ChatSection: Sendable, Hashable, Identifiable {
    /// A list of rows, or a grid of pictures (the inbox's pinned chats, as Messages pins them).
    public enum Style: Sendable, Hashable { case list, grid }

    public var id: String
    public var title: String?
    public var rows: [ChatRow]
    public var style: Style
    public init(id: String, title: String?, rows: [ChatRow], style: Style = .list) {
        self.id = id; self.title = title; self.rows = rows; self.style = style
    }

    /// The inbox's pinned chats.
    public static let pinnedId = "pinned"
}

/// One network's room of a merged chat.
public struct ChatRoom: Hashable, Sendable, Identifiable {
    public var id: String
    public var network: String
    public init(id: String, network: String) { self.id = id; self.network = network }
}

/// One row of the chat list: only what the row shows, so equal rows render the same.
public struct ChatRow: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// The newest message as one line, with its sender in a group ("Anna: hi", "You: ok").
    public var preview: String
    public var date: Date?
    public var unreadCount: Int
    public var isMarkedUnread: Bool
    public var isMuted: Bool
    public var network: String
    public var avatar: ImageRef?
    /// A group with no picture of its own: two members' pictures, drawn as one (Messenger's way).
    public var memberAvatars: [ImageRef] = []
    /// When to answer it, if the user asked to be reminded (and has not answered since).
    public var reminder: Date?
    /// More than two people: messages show their sender's name.
    public var isGroup: Bool
    public var folder: ChatFolder
    /// Pinned on top of the inbox, in `pinOrder` (lower first; nil after those with one).
    public var isPinned = false
    public var pinOrder: Double?
    /// One person's chats on several networks shown as one (merged): its rooms, in the user's
    /// order; empty for any other chat.
    public var rooms: [ChatRoom] = []
    /// The room a merged chat writes to unless the user picks another.
    public var defaultRoom: String?

    public var isUnread: Bool { unreadCount > 0 || isMarkedUnread }
    public var isMerged: Bool { !rooms.isEmpty }
    /// The rooms the chat shows: a merged chat's, else its own.
    public var chatRooms: [ChatRoom] { isMerged ? rooms : [ChatRoom(id: id, network: network)] }

    public init(id: String, name: String, preview: String, date: Date?, unreadCount: Int = 0, isMarkedUnread: Bool = false,
                isMuted: Bool = false, network: String = "matrix", avatar: ImageRef? = nil, isGroup: Bool = false,
                folder: ChatFolder = .inbox) {
        self.id = id
        self.name = name
        self.preview = preview
        self.date = date
        self.unreadCount = unreadCount
        self.isMarkedUnread = isMarkedUnread
        self.isMuted = isMuted
        self.network = network
        self.avatar = avatar
        self.isGroup = isGroup
        self.folder = folder
    }
}
