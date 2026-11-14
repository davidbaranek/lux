import AppKit
import LuxCore

/// The Message menu's Send Later submenu: the times offered now, each with when it is, built
/// again each time it opens. Its items go to the open chat (`ThreadController.sendLater`), which
/// enables them when something is written; an encrypted chat says it cannot hold a message.
@MainActor
final class SendLaterMenu: NSObject, NSMenuDelegate {
    static let shared = SendLaterMenu()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let action = #selector(ThreadController.sendLater(_:))
        if let thread = NSApp.target(forAction: action) as? ThreadController, !thread.canSendLater {
            let note = NSMenuItem(title: String(localized: "Not in encrypted chats"), action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
            return
        }
        for time in LaterTime.offered() {
            let date = time.date()
            let item = NSMenuItem(title: time.title, action: action, keyEquivalent: "")
            item.subtitle = TimeText.upcoming(date)
            item.image = NSImage(systemSymbolName: time.symbol, accessibilityDescription: nil)
            item.representedObject = date
            menu.addItem(item)
        }
    }
}

/// The Message menu's Send Through submenu: a merged chat's networks, the one a new message goes
/// to ticked; an item sends what is written through that network (`ThreadController.sendThrough`).
@MainActor
final class SendThroughMenu: NSObject, NSMenuDelegate {
    static let shared = SendThroughMenu()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let action = #selector(ThreadController.sendThrough(_:))
        guard let thread = NSApp.target(forAction: action) as? ThreadController, thread.rooms.count > 1 else {
            let note = NSMenuItem(title: String(localized: "Only in merged chats"), action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
            return
        }
        for room in thread.rooms {
            let item = NSMenuItem(title: Networks.name(room.network), action: action, keyEquivalent: "")
            item.representedObject = room.id
            item.state = room.id == thread.sendRoom ? .on : .off
            menu.addItem(item)
        }
    }
}
