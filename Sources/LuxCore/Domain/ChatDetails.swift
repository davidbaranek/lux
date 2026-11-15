import Foundation

/// When a chat's messages notify the user.
public enum NotificationSetting: Sendable, Hashable, CaseIterable {
    /// As the account's settings say for a chat of its kind.
    case `default`
    case all
    /// Only mentions of the account and its keywords.
    case mentions
    /// Nothing (a mention still shows in the list).
    case off

    public var title: String {
        switch self {
        case .default: String(localized: "Default")
        case .all: String(localized: "All Messages")
        case .mentions: String(localized: "Mentions and Keywords")
        case .off: String(localized: "Mute")
        }
    }

    public var symbol: String {
        switch self {
        case .default: "bell.badge"
        case .all: "bell"
        case .mentions: "at"
        case .off: "bell.slash"
        }
    }

    /// Whether it keeps the chat quiet, its badge grey: off, or mentions only.
    public var isQuiet: Bool { self == .off || self == .mentions }

    /// The menus' heading.
    public static let menuTitle = String(localized: "Notifications")
}

/// One room of a chat (a merged chat has one per network), as its details show it.
public struct RoomInfo: Sendable, Hashable, Identifiable {
    public var id: String
    public var network: String
    public var name: String
    public var topic: String?
    public var avatar: ImageRef?
    /// Its address (`#room:server`), to share.
    public var address: String?
    public var isEncrypted: Bool
    public var isDirect: Bool
    public var joinedMembers: Int
    public var notifications: NotificationSetting
    public var canRename: Bool
    public var canChangeTopic: Bool
    public var canChangeAvatar: Bool
}

/// A chat's details: its rooms, and their one notification setting (nil when a merged chat's
/// rooms differ).
public struct ChatInfo: Sendable, Hashable {
    public var rooms: [RoomInfo]
    public var notifications: NotificationSetting?

    /// Every room is end-to-end encrypted.
    public var isEncrypted: Bool { !rooms.isEmpty && rooms.allSatisfy(\.isEncrypted) }
}

/// What a member may do in a room.
public enum MemberRole: Sendable, Hashable {
    case creator, admin, moderator, member

    /// Its name, beside the member's; nil for an ordinary member.
    public var title: String? {
        switch self {
        case .creator: String(localized: "Owner")
        case .admin: String(localized: "Admin")
        case .moderator: String(localized: "Moderator")
        case .member: nil
        }
    }
}

/// Someone who joined a chat.
public struct ChatMember: Sendable, Hashable, Identifiable {
    /// Their Matrix id.
    public var id: String
    public var name: String
    public var avatar: ImageRef?
    public var role: MemberRole
    public var isOwn: Bool
}

/// Which list of what a chat shared.
public enum SharedKind: Sendable, Hashable, CaseIterable {
    case media, files, links

    public var title: String {
        switch self {
        case .media: String(localized: "Media")
        case .files: String(localized: "Files")
        case .links: String(localized: "Links")
        }
    }

    public var symbol: String {
        switch self {
        case .media: "photo.on.rectangle"
        case .files: "doc"
        case .links: "link"
        }
    }
}

/// Something shared in a chat: a photo or a video, a file, a link.
public struct SharedItem: Sendable, Hashable, Identifiable {
    public enum Content: Sendable, Hashable {
        case photo(MessageItem.Photo)
        /// Its poster, when the sender sent one.
        case video(poster: MessageItem.Photo?, duration: TimeInterval?)
        case file(name: String, size: Int?, mimetype: String)
        /// The message's text around it.
        case link(URL, text: String)
    }

    /// Unique in its list: a message with two links shares two.
    public var id: String
    public var eventId: String
    public var roomId: String
    public var senderName: String
    public var date: Date
    public var content: Content

    /// Its picture: a photo's thumbnail, a video's poster.
    public var picture: MessageItem.Photo? {
        switch content {
        case .photo(let photo): photo
        case .video(let poster, _): poster
        case .file, .link: nil
        }
    }
}

extension URL {
    /// A web address as a list shows it: without its scheme or a trailing slash
    /// ("example.org/plan").
    public var shownAddress: String {
        let path = path(percentEncoded: false)
        return (host() ?? absoluteString) + (path == "/" ? "" : path)
    }
}
