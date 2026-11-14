import AppKit
import LuxCore

/// The composer: writing, formatting, sending (now, through a network, later) and attaching.
extension ThreadController {
    /// Message › Send Through: sends what is written through that network (the item's room).
    @objc func sendThrough(_ sender: NSMenuItem) {
        guard let room = sender.representedObject as? String else { return }
        model.send(field.stringValue, via: room)
        field.stringValue = ""
        updateEye()
    }

    // MARK: Format (the Format menu, ⌘B, ⌘I, ⇧⌘X, ⌘K)

    @objc func formatBold(_ sender: Any?) { format(Markdown.boldMark) }
    @objc func formatItalic(_ sender: Any?) { format(Markdown.italicMark) }
    @objc func formatStrikethrough(_ sender: Any?) { format(Markdown.strikethroughMark) }
    @objc func formatCode(_ sender: Any?) { format(Markdown.codeMark) }

    private func format(_ mark: String) {
        if field.currentEditor() == nil { view.window?.makeFirstResponder(field) }
        guard let editor = field.currentEditor() as? NSTextView else { return }
        MarkdownStyler.toggle(mark, in: editor)
    }

    /// The eye sits beside the composer, which makes room for it.
    func updateEye() {
        let shows = model.needsReadReceipt && field.stringValue.isEmpty
        guard shows == eye.isHidden else { return }
        eye.isHidden = !shows
        // off before on: the two never hold at once.
        (shows ? glassToEdge : glassBesideEye).isActive = false
        (shows ? glassBesideEye : glassToEdge).isActive = true
    }

    func controlTextDidChange(_ notification: Notification) {
        if let editor = field.currentEditor() as? NSTextView, let font = field.font { MarkdownStyler.style(editor, font: font) }
        updateEye()
        model.composerChanged(field.stringValue)
    }

    func showTyping(_ typists: [Typist]) {
        if let text = TypingText.text(typists.map(\.name)) { typing.stringValue = text }
        if typingShown != !typists.isEmpty {
            typingShown = !typists.isEmpty
            view.needsLayout = true
        }
        if let first = typists.first { typingAvatar.show(first.avatar, name: first.name, images: session.images) }
        // it rises from the composer as it fades in, and sinks back as it goes.
        if !typists.isEmpty, typing.alphaValue == 0 {
            typingBottom.constant = Self.typingAway
            view.layoutSubtreeIfNeeded()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.1)
            context.allowsImplicitAnimation = true
            typing.animator().alphaValue = typists.isEmpty ? 0 : 1
            typingAvatar.animator().alphaValue = typists.isEmpty ? 0 : 1
            typingGlass.animator().alphaValue = typists.isEmpty ? 0 : 1
            typingBottom.animator().constant = typists.isEmpty ? Self.typingAway : Self.typingRest
            view.layoutSubtreeIfNeeded()
        }
    }

    @objc func send() {
        model.send(field.stringValue)
        field.stringValue = ""
        updateEye()
    }

    /// File > Attach Files…, or the + : the open panel, as a sheet; each file goes as a message.
    @objc func attachFiles(_ sender: Any?) {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = String(localized: "Send")
        panel.beginSheetModal(for: window) { [weak self, panel] response in
            MainActor.assumeIsolated {
                if response == .OK { self?.model.attach(panel.urls) }
            }
        }
    }

    // MARK: Send Later (the Message menu's submenu, `SendLaterMenu`)

    /// Whether this chat can hold a message for later: not an encrypted one.
    var canSendLater: Bool { model.canSendLater }

    /// Sends what is written at the item's time (its `representedObject`).
    @objc func sendLater(_ sender: NSMenuItem) {
        guard let date = sender.representedObject as? Date else { return }
        model.sendLater(field.stringValue, at: date)
        field.stringValue = ""
        updateEye()
    }

    /// Send Later needs words to send and a chat that can hold them.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(sendThrough(_:)) { return !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard item.action == #selector(sendLater(_:)) else { return true }
        return model.canSendLater && !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Return sends; Option-Return adds a line.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)), !(NSApp.currentEvent?.modifierFlags.contains(.option) ?? false) {
            send()
            return true
        }
        // Escape leaves a reply or an edit.
        if selector == #selector(NSResponder.cancelOperation(_:)), model.mode != .message {
            if case .edit = model.mode { field.stringValue = "" }
            model.cancelMode()
            return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)) || selector == #selector(NSResponder.insertLineBreak(_:)) {
            textView.insertNewlineIgnoringFieldEditor(nil)
            return true
        }
        return false
    }
}
