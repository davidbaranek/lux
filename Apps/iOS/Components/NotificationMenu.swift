import LuxCore
import UIKit

/// When a chat's messages notify, or each chat's of a network or a space, as a menu: the current
/// choice ticked (none when they differ). The details screen offers the same.
@MainActor
enum NotificationMenu {
    /// The choices, inline: the details screen's pop-up.
    static func choices(current: NotificationSetting?, choose: @escaping @MainActor (NotificationSetting) -> Void) -> UIMenu {
        UIMenu(options: .singleSelection, children: NotificationSetting.allCases.map { setting in
            UIAction(title: setting.title, image: UIImage(systemName: setting.symbol), state: setting == current ? .on : .off) { _ in
                choose(setting)
            }
        })
    }

    /// The choices as a submenu, titled Notifications, with the current one under the title.
    static func menu(current: NotificationSetting?, choose: @escaping @MainActor (NotificationSetting) -> Void) -> UIMenu {
        let menu = UIMenu(title: NotificationSetting.menuTitle, image: UIImage(systemName: (current ?? .default).symbol),
                          children: choices(current: current, choose: choose).children)
        menu.subtitle = current?.title ?? String(localized: "Mixed")
        return menu
    }
}
