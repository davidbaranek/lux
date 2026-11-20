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

    /// Runs the item's action over the text written, in place: the field shows it working, then
    /// the result over the text with ✓ (applied as one edit Undo takes back) and ✕.
    @objc func runTextAction(_ sender: NSMenuItem) {
        guard let action = (sender.representedObject as? TextActionBox)?.action, reviewed == nil else { return }
        let text = composerField.text
        beginReview(action)
        let chat = TextActionChat(name: row.name, network: Networks.name(row.network), isGroup: row.isGroup,
                                  myName: session.profile?.profile?.name, messages: model.messages)
        Task { [weak self] in
            guard let actions = self?.session.textActions else { return }
            do {
                let result = try await actions.run(action, on: text, in: chat)
                self?.showReview(result, of: text)
            } catch {
                self?.reviewBar.showResult(note: error.localizedDescription, canApply: false)
            }
        }
    }

    private func beginReview(_ action: TextAction) {
        reviewed = composerField.text
        field.isEditable = false
        reviewBar.onReject = { [weak self] in self?.endReview(applying: nil) }
        reviewBar.showWorking(symbol: action.symbol, title: action.title)
        reviewBar.isHidden = false
        composerContent?.edgeInsets.top = ComposerReviewBar.gap
    }

    private func showReview(_ result: TextActionResult, of text: String) {
        guard reviewed != nil else { return }
        let applied = result.applied(to: text)
        reviewBar.onAccept = { [weak self] in self?.endReview(applying: applied) }
        if applied != nil, let font = field.font {
            field.textStorage?.setAttributedString(Self.review(result.preview(of: text), font: font))
            // the field takes the result's height, as when the user types.
            _ = composerField.textChanged()
        }
        let note = result.note(over: text)
        reviewBar.showResult(note: note, canApply: applied != nil)
    }

    /// Ends the review: the text as written (✕), or `new` in its place (✓).
    private func endReview(applying new: String?) {
        guard let original = reviewed else { return }
        reviewed = nil
        field.isEditable = true
        field.string = original
        if let font = field.font { MarkdownStyler.style(field, font: font) }
        _ = composerField.textChanged()
        reviewBar.isHidden = true
        composerContent?.edgeInsets.top = 9
        if let new { replaceComposerText(with: new) }
        view.window?.makeFirstResponder(field)
    }

    /// The runs as text: kept as it is, removed struck through in grey, added softly marked.
    private static func review(_ runs: [TextActionChange], font: NSFont) -> NSAttributedString {
        let text = NSMutableAttributedString()
        for run in runs {
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            switch run.kind {
            case .kept: break
            case .removed:
                attributes[.foregroundColor] = NSColor.secondaryLabelColor
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            case .added:
                attributes[.backgroundColor] = NSColor.controlAccentColor.withAlphaComponent(0.28)
            }
            text.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        return text
    }

    /// `new` in place of the composer's text, as the user's own edit.
    func replaceComposerText(with new: String) {
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
