import AppKit
import LuxCore

/// The composer: writing, formatting, sending (now, through a network, later) and attaching.
extension ThreadController {
    /// Message › Send Through: sends what is written through that network (the item's room).
    @objc func sendThrough(_ sender: NSMenuItem) {
        guard reviewed == nil, let room = sender.representedObject as? String else { return }
        model.send(composerField.composed, via: room)
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
        updateMentionQuery()
    }

    /// Sent: the composer empties and goes back to one line.
    private func clearComposer() {
        composerField.composed = ""
        updateEye()
        updateMentionQuery()
    }

    // MARK: Mentions

    /// The `@` and the word before the caret (unless a pill holds the `@`): the members it offers
    /// show above the composer, once the room's are loaded; a newer word's answer replaces an
    /// older one's.
    func updateMentionQuery() {
        let selection = field.selectedRange()
        var query: MentionQuery?
        if selection.length == 0, !field.hasMarkedText(), let storage = field.textStorage,
           let found = ComposedText.mentionQuery(in: field.string, cursor: selection.location),
           !ComposerPills.ranges(in: storage).contains(where: { NSIntersectionRange($0, found.range).length > 0 }) {
            query = found
        }
        guard query != mentionQuery else { return }
        mentionQuery = query
        guard let query else { return mentions.show([]) }
        tasks.run("mention suggestions") { [weak self] in
            guard let self else { return }
            let found = await model.mentionSuggestions(query.text)
            guard mentionQuery == query else { return }
            mentions.show(found)
        }
    }

    /// Puts the pill of `suggestion` in the place of the `@` and its word, as an undoable change.
    func pickMention(_ suggestion: MentionSuggestion) {
        guard let query = mentionQuery, let storage = field.textStorage, NSMaxRange(query.range) <= storage.length else { return }
        let (_, name) = suggestion.pill
        guard field.shouldChangeText(in: query.range, replacementString: name + " ") else { return }
        let caret = ComposerPills.insert(suggestion, replacing: query.range, in: storage, attributes: field.typingAttributes)
        field.didChangeText()
        field.setSelectedRange(NSRange(location: caret, length: 0))
        updateMentionQuery()
    }

    /// An edit that cuts into a pill takes the whole pill: it is replaced over the pill's run.
    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString text: String?) -> Bool {
        guard let storage = textView.textStorage, let text else { return true }
        let whole = ComposerPills.expanded(range, in: storage)
        guard whole != range else { return true }
        if textView.shouldChangeText(in: whole, replacementString: text) {
            textView.replaceCharacters(in: whole, with: text)
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: whole.location + (text as NSString).length, length: 0))
        }
        return false
    }

    /// The caret never rests inside a pill.
    func textView(_ textView: NSTextView, willChangeSelectionFromCharacterRange old: NSRange,
                  toCharacterRange new: NSRange) -> NSRange {
        guard new.length == 0, let storage = textView.textStorage else { return new }
        return ComposerPills.expanded(new, in: storage)
    }

    /// What is typed after a pill is plain text; the mention being typed follows the caret.
    func textViewDidChangeSelection(_ notification: Notification) {
        if field.typingAttributes[.mention] != nil {
            field.typingAttributes.removeValue(forKey: .mention)
            if let font = field.font { field.typingAttributes = [.font: font, .foregroundColor: NSColor.labelColor] }
        }
        updateMentionQuery()
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

    /// Sends what is written; nothing while an AI action's result is shown over it (✓ or ✕
    /// first).
    @objc func send() {
        guard reviewed == nil else { return }
        model.send(composerField.composed)
        clearComposer()
    }

    /// The + : its menu, under it (above near the screen's bottom), for the composer (Continuity Camera's items go to it).
    @objc func showAttachMenu(_ sender: NSButton) {
        view.window?.makeFirstResponder(field)
        if let menu = sender.menu { addTextActions(to: menu) }
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
        guard reviewed == nil, let date = sender.representedObject as? Date else { return }
        model.sendLater(composerField.composed, at: date)
        clearComposer()
    }

    /// Send Later needs words to send and a chat that can hold them; an AI action, text it can
    /// work on.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        // an AI action's result over the text: nothing goes until ✓ or ✕.
        let written = reviewed == nil && !composerField.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if item.action == #selector(sendThrough(_:)) { return written }
        if item.action == #selector(runTextAction(_:)) { return validateTextAction(item) }
        guard item.action == #selector(sendLater(_:)) else { return true }
        return model.canSendLater && written
    }

    /// Return sends; Option-Return adds a line; Tab moves on, as from a text field. While members
    /// are offered for a mention, the arrows choose one, Return or Tab picks it and Escape closes
    /// the list.
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if !mentions.isHidden {
            switch selector {
            case #selector(NSResponder.moveUp(_:)): mentions.move(by: -1); return true
            case #selector(NSResponder.moveDown(_:)): mentions.move(by: 1); return true
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
                if let selected = mentions.selected { pickMention(selected) }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                mentions.show([])
                return true
            default: break
            }
        }
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
