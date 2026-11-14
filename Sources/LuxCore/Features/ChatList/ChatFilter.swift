import Foundation

/// Which of a place's chats the list shows: all of them, or only those of one kind. The core
/// applies it (`lux_core::list`); here its title and symbol.
public enum ChatFilter: String, CaseIterable, Sendable {
    case unread, read, drafts, groups, directs

    public var title: String {
        switch self {
        case .unread: String(localized: "Unread")
        case .read: String(localized: "Read")
        case .drafts: String(localized: "Drafts")
        case .groups: String(localized: "Groups")
        case .directs: String(localized: "Direct Messages")
        }
    }

    public var symbol: String {
        switch self {
        case .unread: "envelope.badge"
        case .read: "envelope.open"
        case .drafts: "pencil"
        case .groups: "person.3"
        case .directs: "person"
        }
    }
}
