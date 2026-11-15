import AppKit
import LuxCore

/// How much of a place, or of one chat, the inbox shows, as a menu item with a submenu; the
/// current choice ticked. Each choice calls `action` on `target` with a `Choice`.
@MainActor
enum InboxMenu {
    /// A network's or a space's: all its chats, those that call for the user, or none.
    static func item(place: Place, current: InboxRule, target: AnyObject, action: Selector) -> NSMenuItem {
        let submenu = NSMenu()
        for rule in InboxRule.allCases {
            submenu.addItem(entry(rule.placeTitle, rule, current: current, choice: Choice(place: place, chatId: nil, rule: rule),
                                  target: target, action: action))
        }
        return heading(submenu)
    }

    /// A chat's: as its places say (nil), or always, when it mentions the user (a group's only),
    /// never.
    static func item(chatId: String, isGroup: Bool, current: InboxRule?, target: AnyObject, action: Selector) -> NSMenuItem {
        let submenu = NSMenu()
        let follows = entry(InboxRule.followPlaces, nil, current: current, choice: Choice(place: nil, chatId: chatId, rule: nil),
                            target: target, action: action)
        submenu.addItem(follows)
        submenu.addItem(.separator())
        for rule in InboxRule.allCases where isGroup || rule != .mentions {
            submenu.addItem(entry(rule.chatTitle, rule, current: current, choice: Choice(place: nil, chatId: chatId, rule: rule),
                                  target: target, action: action))
        }
        return heading(submenu)
    }

    private static func heading(_ submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: InboxRule.menuTitle, action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "tray", accessibilityDescription: nil)
        item.submenu = submenu
        return item
    }

    private static func entry(_ title: String, _ rule: InboxRule?, current: InboxRule?, choice: Choice,
                              target: AnyObject, action: Selector) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = target
        entry.representedObject = choice
        entry.image = rule.flatMap { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: nil) }
        entry.state = current == rule ? .on : .off
        return entry
    }

    /// What an item chooses: a place's rule, or a chat's (nil: as its places say).
    final class Choice: NSObject {
        let place: Place?
        let chatId: String?
        let rule: InboxRule?
        init(place: Place?, chatId: String?, rule: InboxRule?) { self.place = place; self.chatId = chatId; self.rule = rule }
    }
}
