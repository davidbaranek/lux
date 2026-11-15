/// How much of a network's or a space's chats the inbox shows, or of one chat
/// (`lux_core::places::InboxRule`). A chat kept out stays in its places; its own rule beats its
/// places', and of its places the strictest counts. The account keeps them.
public enum InboxRule: String, CaseIterable, Hashable, Sendable {
    /// Everything, as the inbox always did.
    case all
    /// Conversations of two, and groups while they mention the user.
    case mentions
    /// Nothing: its chats are read in their places only.
    case never

    /// What a place's menu calls it.
    public var placeTitle: String {
        switch self {
        case .all: String(localized: "All Chats")
        case .mentions: String(localized: "Direct Messages and Mentions")
        case .never: String(localized: "None")
        }
    }

    /// What a chat's menu calls it.
    public var chatTitle: String {
        switch self {
        case .all: String(localized: "Always")
        case .mentions: String(localized: "When Mentioned")
        case .never: String(localized: "Never")
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

    /// The menus' heading.
    public static let menuTitle = String(localized: "Show in Inbox")
    /// The inbox's menu, with every network's and space's rule.
    public static let overviewTitle = String(localized: "What Inbox Shows")
    /// A chat's choice to follow its places.
    public static let followPlaces = String(localized: "As Its Places Say")
}
