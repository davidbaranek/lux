import AppKit
import LuxCore

/// When a chat's messages notify, or each chat's of a network or a space, as a menu item with a
/// submenu: the current choice ticked (none when they differ) and under the title. The details
/// offer the same. Each choice calls `action` on `target` with a `Choice`.
@MainActor
enum NotificationMenu {
    static func item(chatId: String? = nil, place: Place? = nil, current: NotificationSetting?, target: AnyObject,
                     action: Selector) -> NSMenuItem {
        let submenu = NSMenu()
        for setting in NotificationSetting.allCases {
            let entry = NSMenuItem(title: setting.title, action: action, keyEquivalent: "")
            entry.target = target
            entry.representedObject = Choice(chatId: chatId, place: place, setting: setting)
            entry.image = NSImage(systemSymbolName: setting.symbol, accessibilityDescription: nil)
            entry.state = current == setting ? .on : .off
            submenu.addItem(entry)
        }
        let item = NSMenuItem(title: NotificationSetting.menuTitle, action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: (current ?? .default).symbol, accessibilityDescription: nil)
        item.subtitle = current?.title ?? String(localized: "Mixed")
        item.submenu = submenu
        return item
    }

    /// What an item chooses: a chat's setting, or each chat's of a place.
    final class Choice: NSObject {
        let chatId: String?
        let place: Place?
        let setting: NotificationSetting
        init(chatId: String?, place: Place?, setting: NotificationSetting) {
            self.chatId = chatId; self.place = place; self.setting = setting
        }
    }
}
