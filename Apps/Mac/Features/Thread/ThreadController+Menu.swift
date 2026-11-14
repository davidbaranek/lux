import AppKit
import LuxCore

/// A message's right-click menu (reactions and actions), and the eye's menu of read receipts.
extension ThreadController {
    /// The message's own menu, opened from its row (the table would outline the whole row if it
    /// owned the menu).
    func menu(for id: String) -> NSMenu? {
        guard let message = messages[id] else { return nil }
        let menu = NSMenu()
        if MessageAction.canReact(to: message) {
            let mine = Set(message.reactions.filter(\.isMine).map(\.key))
            let palette = NSMenu()
            palette.presentationStyle = .palette
            for key in ThreadModel.quickReactions {
                let item = NSMenuItem(title: key, action: #selector(react(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = [id, key]
                item.image = EmojiImage.image(key)
                item.state = mine.contains(key) ? .on : .off
                palette.addItem(item)
            }
            let more = NSMenuItem(title: String(localized: "More Reactions"), action: #selector(moreReactions(_:)), keyEquivalent: "")
            more.target = self
            more.representedObject = id
            more.image = NSImage(systemSymbolName: "plus", accessibilityDescription: String(localized: "More Reactions"))
            palette.addItem(more)
            let react = NSMenuItem(title: String(localized: "React"), action: nil, keyEquivalent: "")
            react.submenu = palette
            menu.addItem(react)
            menu.addItem(.separator())
        }
        // a shared post's address, whole, to read: Copy Link copies it.
        if let link = message.shared?.url {
            let address = NSMenuItem.sectionHeader(title: link)
            address.toolTip = link
            menu.addItem(address)
        }
        for action in MessageAction.available(for: message) {
            if action.isDestructive { menu.addItem(.separator()) }
            let item = NSMenuItem(title: action.title, action: #selector(performAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = MenuAction(action: action, message: message)
            item.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }
        return menu
    }

    /// A message action from the menu, with the message it was asked for.
    private final class MenuAction {
        let action: MessageAction
        let message: MessageItem
        init(action: MessageAction, message: MessageItem) { self.action = action; self.message = message }
    }

    @objc private func performAction(_ item: NSMenuItem) {
        guard let chosen = item.representedObject as? MenuAction else { return }
        let message = chosen.message
        switch chosen.action {
        case .reply: model.reply(to: message)
        case .edit: model.edit(message)
        case .copy:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(message.body, forType: .string)
        case .copyLink:
            guard let link = message.shared?.url else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link, forType: .string)
        case .save: model.save(message)
        case .unsave: model.unsave(message)
        case .retry: model.retry(message.id)
        case .discard: model.discard(message.id)
        case .forward:
            let picker = ChatPickerController(session: session, title: String(localized: "Forward To"), action: String(localized: "Forward")) { [weak self] target in
                self?.model.forward(message.id, to: target.id)
            }
            presentAsSheet(picker)
        case .delete:
            guard let window = view.window else { return }
            let alert = NSAlert()
            alert.messageText = String(localized: "Delete this message for everyone?")
            alert.informativeText = String(localized: "It is removed for everyone in the chat, on every network the chat is on.")
            alert.addButton(withTitle: String(localized: "Delete"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            alert.buttons.first?.hasDestructiveAction = true
            alert.beginSheetModal(for: window) { [weak self] response in
                if response == .alertFirstButtonReturn { self?.model.delete(message.id) }
            }
        }
    }

    /// Any emoji as a reaction: the system's Character Viewer types into an invisible field.
    @objc private func moreReactions(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String else { return }
        emojiPicker.pick(in: view) { [weak self] emoji in
            self?.model.toggleReaction(emoji, on: id)
            self?.view.window?.makeFirstResponder(self?.field)
        }
    }

    @objc private func react(_ item: NSMenuItem) {
        guard let pair = item.representedObject as? [String] else { return }
        model.toggleReaction(pair[1], on: pair[0])
    }
}

extension ThreadController: NSMenuDelegate {
    /// The eye's menu: automatically, manually, or as Settings says; the current choice is ticked.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let header = NSMenuItem(title: String(localized: "Read Receipts in This Chat"), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let app = Preferences.shared.sendsReadReceipts ? String(localized: "Automatically") : String(localized: "Manually")
        let choices: [(String, ReadReceipts?)] = [(String(localized: "Automatically"), .automatic), (String(localized: "Manually"), .manual),
                                                  (String(localized: "As in Settings (\(app))"), nil)]
        for (index, (title, mode)) in choices.enumerated() {
            let item = NSMenuItem(title: title, action: #selector(chooseReadReceipts(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = model.readReceiptsOverride == mode ? .on : .off
            menu.addItem(item)
        }
    }

    @objc private func chooseReadReceipts(_ item: NSMenuItem) {
        model.readReceiptsOverride = [ReadReceipts.automatic, .manual, nil][item.tag]
        let clip = scroll.contentView
        if table.bounds.height + scroll.contentInsets.bottom - clip.bounds.maxY < 40 { model.didReadLatest() }
    }
}
