/// How much of a network's or a space's chats the inbox shows (`lux_core::places::InboxRule`).
/// What a rule keeps out is of low priority, and stays in its places; of a chat's places the
/// strictest counts, and a pinned chat stays in the inbox. The account keeps them.
public enum InboxRule: String, CaseIterable, Hashable, Sendable {
    /// Everything, as the inbox always did.
    case all
    /// Conversations of two, and groups while they mention the user.
    case mentions
    /// Nothing: its chats are read in their places, and in low priority.
    case never

    /// What a place's menu calls it.
    public var title: String {
        switch self {
        case .all: String(localized: "All Chats")
        case .mentions: String(localized: "Direct Messages and Mentions")
        case .never: String(localized: "None")
        }
    }

    /// Its SF Symbol.
    public var symbol: String {
        switch self {
        case .all: "tray.full"
        case .mentions: "at"
        case .never: "minus.circle"
        }
    }

    /// What a chat's details say of a chat this rule of `place` keeps out of the inbox.
    public func keepsOut(by place: String) -> String {
        switch self {
        case .all: ""
        case .mentions: String(localized: "In Low Priority: Inbox shows only direct messages and mentions of \(place).")
        case .never: String(localized: "In Low Priority: Inbox shows no chats of \(place).")
        }
    }

    /// The menu's heading.
    public static let menuTitle = String(localized: "Show in Inbox")
}
