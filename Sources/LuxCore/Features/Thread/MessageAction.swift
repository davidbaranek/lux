import Foundation

/// What a message's menu offers. The rules live here, so both apps offer the same.
public enum MessageAction: Hashable, Sendable {
    case reply, edit, copy, copyLink, save, unsave, forward, delete, retry, discard

    /// The actions for `message`, in menu order (reactions come before them, where they apply).
    public static func available(for message: MessageItem) -> [MessageAction] {
        if message.isDeleted { return [] }
        switch message.state {
        case .failed: return [.retry, .discard] + (message.body.isEmpty ? [] : [.copy])
        case .sending: return message.body.isEmpty ? [] : [.copy]
        case .sent: break
        }
        var actions: [MessageAction] = [.reply]
        if message.isEditable { actions.append(.edit) }
        if !message.body.isEmpty { actions.append(.copy) }
        if message.shared?.url != nil { actions.append(.copyLink) }
        if !message.eventId.isEmpty { actions.append(message.isSaved ? .unsave : .save) }
        if !message.body.isEmpty || message.photo != nil { actions.append(.forward) }
        if message.isOwn { actions.append(.delete) }
        return actions
    }

    /// Reactions apply to a message the server has.
    public static func canReact(to message: MessageItem) -> Bool {
        !message.isDeleted && message.state == .sent
    }

    public var title: String {
        switch self {
        case .reply: String(localized: "Reply")
        case .edit: String(localized: "Edit")
        case .copy: String(localized: "Copy")
        case .copyLink: String(localized: "Copy Link")
        case .save: String(localized: "Save")
        case .unsave: String(localized: "Remove from Saved")
        case .forward: String(localized: "Forward…")
        case .delete: String(localized: "Delete for Everyone")
        case .retry: String(localized: "Send Again")
        case .discard: String(localized: "Delete")
        }
    }

    public var symbol: String {
        switch self {
        case .reply: "arrowshape.turn.up.left"
        case .edit: "pencil"
        case .copy: "doc.on.doc"
        case .copyLink: "link"
        case .save: "bookmark"
        case .unsave: "bookmark.slash"
        case .forward: "arrowshape.turn.up.right"
        case .delete, .discard: "trash"
        case .retry: "arrow.clockwise"
        }
    }

    public var isDestructive: Bool { self == .delete || self == .discard }
}
