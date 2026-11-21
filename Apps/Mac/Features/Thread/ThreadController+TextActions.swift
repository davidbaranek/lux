import AppKit
import LuxCore

/// The AI actions over the text written: under the + and in the composer's menu, with AI on.
extension ThreadController {
    /// The items of the actions on offer, each running its action; none with AI off.
    func textActionItems() -> [NSMenuItem] {
        session.textActions.actions.map { action in
            let item = NSMenuItem(title: action.title, action: #selector(runTextAction(_:)), keyEquivalent: "")
            item.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)
            item.representedObject = TextActionBox(action)
            item.target = self
            return item
        }
    }

    /// The + 's menu with the actions after its own items, under a separator: they change with
    /// the switch, so they are made each time it opens.
    func addTextActions(to menu: NSMenu) {
        for item in menu.items where item.representedObject is TextActionBox || item.identifier == Self.textActionsSeparator {
            menu.removeItem(item)
        }
        let items = textActionItems()
        guard !items.isEmpty else { return }
        let separator = NSMenuItem.separator()
        separator.identifier = Self.textActionsSeparator
        menu.addItem(separator)
        items.forEach(menu.addItem)
    }

    private static var textActionsSeparator: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier("textActions") }

    /// The composer's own menu (Control-click) with the actions at its top.
    func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
        let items = textActionItems()
        guard !items.isEmpty else { return menu }
        menu.insertItem(.separator(), at: 0)
        for item in items.reversed() { menu.insertItem(item, at: 0) }
        return menu
    }

    /// Whether the text written can be worked on now; the item's tooltip says why not.
    func validateTextAction(_ item: NSMenuItem) -> Bool {
        let reason = session.textActions.unavailability(of: composerField.text)
        item.toolTip = reason
        return reason == nil
    }

    /// Runs the item's action over the text written: its sheet works while the model answers,
    /// then shows the result over the text, and Apply puts it in the composer as an edit Undo
    /// takes back.
    @objc func runTextAction(_ sender: NSMenuItem) {
        guard let action = (sender.representedObject as? TextActionBox)?.action else { return }
        let text = composerField.text
        let panel = TextActionPanel(action: action, original: text) { [weak self] new in self?.replaceComposerText(with: new) }
        presentAsSheet(panel)
        let chat = TextActionChat(name: row.name, network: Networks.name(row.network), isGroup: row.isGroup,
                                  myName: session.profile?.profile?.name, messages: model.messages)
        Task { [weak self, weak panel] in
            guard let actions = self?.session.textActions else { return }
            do {
                let result = try await actions.run(action, on: text, in: chat)
                panel?.show(result)
            } catch {
                panel?.show(message: error.localizedDescription)
            }
        }
    }

    /// `new` in place of the composer's text, as the user's own edit.
    private func replaceComposerText(with new: String) {
        let all = NSRange(location: 0, length: (field.string as NSString).length)
        guard field.shouldChangeText(in: all, replacementString: new) else { return }
        field.replaceCharacters(in: all, with: new)
        field.didChangeText()
        view.window?.makeFirstResponder(field)
    }
}

/// An action as a menu item's represented object.
final class TextActionBox: NSObject {
    let action: TextAction
    init(_ action: TextAction) { self.action = action }
}
