import Foundation

extension ChatChange {
    /// What a chat's menu offers, in order: read state, pin, where it lives, delete. Its
    /// notifications are a choice of their own (`NotificationSetting`).
    public static func available(for row: ChatRow) -> [ChatChange] {
        var changes: [ChatChange] = [row.isUnread ? .read : .unread, row.isPinned ? .unpin : .pin]
        switch row.folder {
        case .inbox: changes += [.lowPriority, .archive]
        case .lowPriority: changes += [.inbox, .archive]
        case .archive: changes += [.unarchive]
        }
        return changes + [.delete]
    }

    public var title: String {
        switch self {
        case .read: String(localized: "Mark as Read")
        case .unread: String(localized: "Mark as Unread")
        case .pin: String(localized: "Pin")
        case .unpin: String(localized: "Unpin")
        case .lowPriority: String(localized: "Move to Low Priority")
        case .inbox: String(localized: "Move to Inbox")
        case .archive: String(localized: "Archive")
        case .unarchive: String(localized: "Unarchive")
        case .delete: String(localized: "Delete Chat…")
        }
    }

    public var symbol: String {
        switch self {
        case .read: "envelope.open"
        case .unread: "envelope.badge"
        case .pin: "pin"
        case .unpin: "pin.slash"
        case .lowPriority: "arrow.down.circle"
        case .inbox: "tray.and.arrow.up"
        case .archive: "archivebox"
        case .unarchive: "tray.and.arrow.up"
        case .delete: "trash"
        }
    }

    /// Asked for first: it cannot be undone in the app.
    public var needsConfirmation: Bool { self == .delete }
    public var isDestructive: Bool { self == .delete }

    /// What the confirmation says.
    public static let deleteWarning = String(localized: "The chat leaves this app on all your devices until someone writes in it again. You stay in it on its network.")
}
