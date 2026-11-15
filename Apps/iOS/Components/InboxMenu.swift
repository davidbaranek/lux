import LuxCore
import UIKit

/// How much of a place, or of one chat, the inbox shows, as a menu; the current choice ticked.
@MainActor
enum InboxMenu {
    /// A network's or a space's: all its chats, those that call for the user, or none. Titled
    /// Show in Inbox in the place's own menu, by the place's name in the inbox's overview.
    static func place(title: String = InboxRule.menuTitle, image: UIImage? = UIImage(systemName: "tray"), current: InboxRule,
                      choose: @escaping @MainActor (InboxRule) -> Void) -> UIMenu {
        let rules = InboxRule.allCases.map { rule in
            UIAction(title: rule.placeTitle, image: UIImage(systemName: rule.symbol), state: rule == current ? .on : .off) { _ in choose(rule) }
        }
        let menu = UIMenu(title: title, image: image, children: rules)
        menu.subtitle = current.placeTitle
        return menu
    }

    /// The inbox's own: every network's and space's rule in one place, each by its name.
    static func overview(_ places: [PlaceItem], choose: @escaping @MainActor (Place, InboxRule) -> Void) -> UIMenu {
        let groups = [Place.Group.networks, .spaces].map { group in
            UIMenu(options: .displayInline, children: places.filter { $0.id.group == group }.compactMap { item in
                item.inbox.map { current in place(title: item.title, image: nil, current: current) { choose(item.id, $0) } }
            })
        }
        return UIMenu(title: InboxRule.overviewTitle, image: UIImage(systemName: "tray"), children: groups)
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
