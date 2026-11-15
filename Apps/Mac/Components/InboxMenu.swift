import AppKit
import LuxCore

/// How much of a network's or a space's chats the inbox shows, as a menu item with a submenu in
/// the place's own menu; the current choice ticked and under the title. What it keeps out is of
/// low priority. Each choice calls `action` on `target` with a `Choice`.
@MainActor
enum InboxMenu {
    static func item(place: Place, current: InboxRule, target: AnyObject, action: Selector) -> NSMenuItem {
        let submenu = NSMenu()
        for rule in InboxRule.allCases {
            let entry = NSMenuItem(title: rule.title, action: action, keyEquivalent: "")
            entry.target = target
            entry.representedObject = Choice(place: place, rule: rule)
            entry.image = NSImage(systemSymbolName: rule.symbol, accessibilityDescription: nil)
            entry.state = current == rule ? .on : .off
            submenu.addItem(entry)
        }
        let item = NSMenuItem(title: InboxRule.menuTitle, action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "tray", accessibilityDescription: nil)
        item.subtitle = current.title
        item.submenu = submenu
        return item
    }

    /// What an item chooses: a place's rule.
    final class Choice: NSObject {
        let place: Place
        let rule: InboxRule
        init(place: Place, rule: InboxRule) { self.place = place; self.rule = rule }
    }
}
