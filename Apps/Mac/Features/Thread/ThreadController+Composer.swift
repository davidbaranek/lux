import AppKit
import LuxCore

/// The composer: writing, formatting, sending (now, through a network, later) and attaching.
extension ThreadController {
    /// Message › Send Through: sends what is written through that network (the item's room).
    @objc func sendThrough(_ sender: NSMenuItem) {
        guard let room = sender.representedObject as? String else { return }
        model.send(composerField.text, via: room)
        clearComposer()
    }

    // MARK: Format (the Format menu, ⌘B, ⌘I, ⇧⌘X, ⌘K)

    @objc func formatBold(_ sender: Any?) { format(Markdown.boldMark) }
    @objc func formatItalic(_ sender: Any?) { format(Markdown.italicMark) }
    @objc func formatStrikethrough(_ sender: Any?) { format(Markdown.strikethroughMark) }
    @objc func formatCode(_ sender: Any?) { format(Markdown.codeMark) }

    private func format(_ mark: String) {
        view.window?.makeFirstResponder(field)
        MarkdownStyler.toggle(mark, in: field)
    }

    /// The eye sits beside the composer, which makes room for it.
    func updateEye() {
        let shows = model.needsReadReceipt && composerField.text.isEmpty
        guard shows == eye.isHidden else { return }
        eye.isHidden = !shows
        // off before on: the two never hold at once.
        (shows ? glassToEdge : glassBesideEye).isActive = false
        (shows ? glassBesideEye : glassToEdge).isActive = true
    }

    func textDidChange(_ notification: Notification) {
        if let font = field.font { MarkdownStyler.style(field, font: font) }
        updateEye()
        // the composer takes its text's height in the window's next layout, and the messages'
        // bottom inset follows it in the same pass (`viewDidLayout`), keeping the list's place:
        // the two move as one, never the composer over the newest message.
        composerField.textChanged()
        model.composerChanged(composerField.text)
    }

    /// Sent: the composer empties and goes back to one line.
    private func clearComposer() {
        composerField.text = ""
        updateEye()
    }

    /// Pictures, videos and files pasted or dropped into the text: those only on the pasteboard
    /// are written to files first, off the main thread; then they wait in the composer.
    func attachPasted(_ items: [PastedItems.Item]) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pasted", isDirectory: true)
        tasks.run { [weak self] in
            do {
                let files = try await PastedItems.files(items, in: folder)
                self?.model.attach(files)
            } catch {
                self?.report(error, of: "paste")
            }
        }
    }

    func showTyping(_ typists: [Typist]) {
        if let text = TypingText.text(typists.map(\.name)) { typing.stringValue = text }
        if typingShown != !typists.isEmpty {
            typingShown = !typists.isEmpty
            view.needsLayout = true
        }
        if let first = typists.first { typingAvatar.show(first.avatar, name: first.name, images: session.images) }
        // it rises from the composer as it fades in, and sinks back as it goes.
        if !typists.isEmpty, typing.isHidden {
            typingBottom.constant = Self.typingAway
            view.layoutSubtreeIfNeeded()
            for view in typingViews { view.isHidden = false }
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.1)
            context.allowsImplicitAnimation = true
            for view in typingViews { view.animator().alphaValue = typists.isEmpty ? 0 : 1 }
            typingBottom.animator().constant = typists.isEmpty ? Self.typingAway : Self.typingRest
            view.layoutSubtreeIfNeeded()
        } completionHandler: { [weak self] in
            // gone, unless someone typed again as it went: a clear line still takes clicks.
            MainActor.assumeIsolated {
                guard let self, !self.typingShown else { return }
                for view in self.typingViews { view.isHidden = true }
            }
        }
    }

    @objc func send() {
        model.send(composerField.text)
        clearComposer()
    }

    /// The + : its menu, under it (above near the screen's bottom), for the composer (Continuity Camera's items go to it).
    @objc func showAttachMenu(_ sender: NSButton) {
        view.window?.makeFirstResponder(field)
        sender.menu?.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.isFlipped ? sender.bounds.maxY + 4 : -4), in: sender)
    }

    /// File > Attach Files…, or the + 's first item: the open panel, as a sheet; each file goes as a message.
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
        model.sendLater(composerField.text, at: date)
        clearComposer()
    }

    /// Send Later needs words to send and a chat that can hold them.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let written = !composerField.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if item.action == #selector(sendThrough(_:)) { return written }
        guard item.action == #selector(sendLater(_:)) else { return true }
        return model.canSendLater && written
    }

    /// Return sends; Option-Return adds a line; Tab moves on, as from a text field.
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)), !(NSApp.currentEvent?.modifierFlags.contains(.option) ?? false) {
            send()
            return true
        }
        // Escape leaves a reply or an edit.
        if selector == #selector(NSResponder.cancelOperation(_:)), model.mode != .message {
            if case .edit = model.mode { clearComposer() }
            model.cancelMode()
            return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)) || selector == #selector(NSResponder.insertLineBreak(_:)) {
            textView.insertNewlineIgnoringFieldEditor(nil)
            return true
        }
        if selector == #selector(NSResponder.insertTab(_:)) {
            view.window?.selectNextKeyView(nil)
            return true
        }
        if selector == #selector(NSResponder.insertBacktab(_:)) {
            view.window?.selectPreviousKeyView(nil)
            return true
        }
        return false
    }
}
