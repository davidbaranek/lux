import Foundation
import LuxBindings

/// What the push gateway sends: only the ids of the event (`event_id_only`), and the server's
/// count of chats with unread notifications.
public struct PushPayload: Sendable, Equatable {
    public var roomId: String
    public var eventId: String
    /// The server's badge: chats with unread notifications. Nil when it sent none.
    public var unreadCount: Int?
    /// The Matrix thread the message replies in, by its root: not the gateway's, but what the
    /// device read of the message adds to the notification (`PushedMessage.userInfo`).
    public var threadRoot: String?

    public init?(userInfo: [AnyHashable: Any]) {
        guard let roomId = userInfo["room_id"] as? String, let eventId = userInfo["event_id"] as? String else { return nil }
        self.roomId = roomId
        self.eventId = eventId
        unreadCount = (userInfo["unread_count"] as? NSNumber)?.intValue
        threadRoot = userInfo[Self.threadRootKey] as? String
    }

    /// Where a notification keeps its message's thread.
    public static let threadRootKey = "thread_root"
}

extension PushedMessage {
    /// What its notification carries for the app: the ids a push carries, and its thread, so
    /// opening it opens the thread and answering it answers there.
    public var userInfo: [String: String] {
        var info = ["room_id": roomId, "event_id": eventId]
        if let threadRoot { info[PushPayload.threadRootKey] = threadRoot }
        return info
    }
}

/// A pushed message, worded: what a notification shows of it.
public struct PushedMessage: Sendable, Equatable {
    public var roomId: String
    public var eventId: String
    /// The chat its notifications group by: the merged chat's id (`merge:…`) when the room is
    /// part of one, else the room's.
    public var chatId: String
    /// The sender in a direct chat, the chat in a group.
    public var title: String
    /// The sender in a group.
    public var subtitle: String
    public var body: String
    public var senderName: String
    public var chatName: String
    public var isGroup: Bool
    /// The push rules give it a sound (never when it came late).
    public var isNoisy: Bool
    /// It came long after it was sent: history a bridge brings in, or a push held back while the
    /// device was away. It shows quietly, without lighting the screen.
    public var isLate: Bool
    /// The sender's picture's image data (a thumbnail), in a group too. Nil when there is none, or
    /// it could not be had in time.
    public var senderImage: Data?
    /// The Matrix thread it replies in, by its root: its notification opens the thread.
    public var threadRoot: String?
}

/// The account as the notification extension sees it: the kept session, opened from the shared
/// container without its sync, reading one pushed event at a time (fetched and decrypted on the
/// device). The extension keeps one per process: iOS may reuse it for the next notification.
public final class PushedEvents: Sendable {
    private let reader: CoreNotificationReader

    private init(reader: CoreNotificationReader) { self.reader = reader }

    /// Opens the kept account; nil when none is kept. Throws when its store cannot be opened (the
    /// core opens a session only over its own encrypted store): the app forgets that account.
    public static func open(configuration: Session.Configuration = .main) async throws -> PushedEvents? {
        // the extension's small runtime, before the first call into the core.
        CoreRuntime.startInExtension()
        let keychain = AccountKeychain(service: configuration.keychainService)
        guard let kept = try keychain.read(), let root = SharedContainer.groupRoot else { return nil }
        let folder = root.appendingPathComponent(kept.store, isDirectory: true)
        let reader = try await openNotificationReader(storeFolder: folder.path, keeper: KeychainKeeper(keychain: keychain, store: kept.store))
        return reader.map(PushedEvents.init)
    }

    /// The pushed event, worded, with its pictures; nil when it is not to be shown (the push
    /// rules filter it out, or it was deleted). Throws when it could not be read.
    public func read(_ payload: PushPayload) async throws -> PushedMessage? {
        switch try await reader.read(roomId: payload.roomId, eventId: payload.eventId) {
        case .shown(let notification): PushedMessage(notification)
        case .filteredOut, .gone: nil
        }
    }
}

extension PushedMessage {
    init(_ notification: CoreNotification) {
        roomId = notification.roomId
        eventId = notification.eventId
        chatId = notification.chatId
        senderImage = notification.senderImage
        senderName = notification.senderName
        chatName = notification.chatName
        isGroup = notification.isGroup
        isNoisy = notification.isNoisy
        isLate = notification.isLate
        threadRoot = notification.threadRoot
        title = notification.isGroup ? notification.chatName : notification.senderName
        subtitle = notification.isGroup ? notification.senderName : ""
        // what happened, worded as the chat list words it, without a name: the title has it.
        body = PreviewLine.words(CorePreview(author: nil, kind: notification.kind))
    }
}
