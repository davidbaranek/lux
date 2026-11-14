import Foundation

/// The order of a place's chats: by their last activity, as the server orders them (the
/// default), or by their newest message. The core applies it (`lux_core::places::ChatOrder`);
/// here its title and symbol.
public enum ChatOrder: String, CaseIterable, Sendable {
    case activity, newestMessage

    public var title: String {
        switch self {
        case .activity: String(localized: "Last Activity")
        case .newestMessage: String(localized: "Newest Message")
        }
    }

    public var symbol: String {
        switch self {
        case .activity: "clock.arrow.circlepath"
        case .newestMessage: "bubble.left"
        }
    }
}
