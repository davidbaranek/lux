import LuxCore
import UIKit

/// How much of a place, or of one chat, the inbox shows, as a menu; the current choice ticked.
@MainActor
enum InboxMenu {
    /// A network's or a space's: all its chats, those that call for the user, or none.
    static func place(current: InboxRule, choose: @escaping @MainActor (InboxRule) -> Void) -> UIMenu {
        let rules = InboxRule.allCases.map { rule in
            UIAction(title: rule.placeTitle, image: UIImage(systemName: rule.symbol), state: rule == current ? .on : .off) { _ in choose(rule) }
        }
        return UIMenu(title: InboxRule.menuTitle, image: UIImage(systemName: "tray"), children: rules)
    }

    /// A chat's: as its places say (nil), or always, when it mentions the user (a group's only),
    /// never.
    static func chat(current: InboxRule?, isGroup: Bool, choose: @escaping @MainActor (InboxRule?) -> Void) -> UIMenu {
        let follows = UIAction(title: InboxRule.followPlaces, state: current == nil ? .on : .off) { _ in choose(nil) }
        let rules = InboxRule.allCases.filter { isGroup || $0 != .mentions }.map { rule in
            UIAction(title: rule.chatTitle, image: UIImage(systemName: rule.symbol), state: rule == current ? .on : .off) { _ in choose(rule) }
        }
        return UIMenu(title: InboxRule.menuTitle, image: UIImage(systemName: "tray"),
                      children: [UIMenu(options: .displayInline, children: [follows]), UIMenu(options: .displayInline, children: rules)])
    }
}
