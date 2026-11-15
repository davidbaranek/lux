import AppKit
import LuxCore

/// How much of a place, or of one chat, the inbox shows, as a menu item with a submenu; the
/// current choice ticked. Each choice calls `action` on `target` with a `Choice`.
@MainActor
enum InboxMenu {
    /// A network's or a space's: all its chats, those that call for the user, or none. Titled
    /// Show in Inbox in the place's own menu, by the place's name in the inbox's overview.
    static func item(place: Place, title: String = InboxRule.menuTitle, current: InboxRule, target: AnyObject,
                     action: Selector) -> NSMenuItem {
        let submenu = NSMenu()
        for rule in InboxRule.allCases {
            submenu.addItem(entry(rule.placeTitle, rule, current: current, choice: Choice(place: place, chatId: nil, rule: rule),
                                  target: target, action: action))
        }
        let item = heading(submenu, title: title)
        item.subtitle = current.placeTitle
        return item
    }

    /// The inbox's own: every network's and space's rule in one place, each by its name.
    static func overview(_ places: [PlaceItem], target: AnyObject, action: Selector) -> NSMenuItem {
        let submenu = NSMenu()
        for group in [Place.Group.networks, .spaces] {
            let items = places.filter { $0.id.group == group }.compactMap { place in
                place.inbox.map { item(place: place.id, title: place.title, current: $0, target: target, action: action) }
            }
            if !items.isEmpty, !submenu.items.isEmpty { submenu.addItem(.separator()) }
            items.forEach(submenu.addItem)
        }
        return heading(submenu, title: InboxRule.overviewTitle)
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

    private static func heading(_ submenu: NSMenu, title: String = InboxRule.menuTitle) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
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
