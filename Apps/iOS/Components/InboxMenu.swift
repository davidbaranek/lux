import LuxCore
import UIKit

/// How much of a network's or a space's chats the inbox shows, as a menu in the place's own: the
/// current choice ticked and under the title. What it keeps out is of low priority.
@MainActor
enum InboxMenu {
    static func place(current: InboxRule, choose: @escaping @MainActor (InboxRule) -> Void) -> UIMenu {
        let rules = InboxRule.allCases.map { rule in
            UIAction(title: rule.title, image: UIImage(systemName: rule.symbol), state: rule == current ? .on : .off) { _ in choose(rule) }
        }
        let menu = UIMenu(title: InboxRule.menuTitle, image: UIImage(systemName: "tray"), children: rules)
        menu.subtitle = current.title
        return menu
    }
}
