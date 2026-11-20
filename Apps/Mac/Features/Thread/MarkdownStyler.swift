import AppKit
import LuxCore

/// Shows the composer's Markdown formatted while it is typed (bold as bold, code fixed-width, the
/// marks dimmed) and its pills as pills, on the composer's text view. Only attributes change: the
/// text, the cursor and undo stay as they are.
@MainActor
enum MarkdownStyler {
    static func style(_ textView: NSTextView, font: NSFont) {
        guard let storage = textView.textStorage else { return }
        let all = NSRange(location: 0, length: storage.length)
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        let pills = ComposerPills.marks(in: storage)
        storage.beginEditing()
        storage.setAttributes(base, range: all)
        ComposerPills.mark(storage, pills)
        for run in Markdown.runs(in: storage.string) where NSMaxRange(run.range) <= storage.length {
            switch run.kind {
            case .bold: add(.bold, to: storage, in: run.range)
            case .italic: add(.italic, to: storage, in: run.range)
            case .strikethrough: storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: run.range)
            case .code, .codeBlock:
                storage.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: font.pointSize * 0.9, weight: .regular),
                                       .backgroundColor: NSColor.quaternaryLabelColor], range: run.range)
            case .quote: storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: run.range)
            case .mark: storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: run.range)
            }
        }
        ComposerPills.style(storage, tint: .controlAccentColor)
        storage.endEditing()
        textView.typingAttributes = base
    }

    private static func add(_ traits: NSFontDescriptor.SymbolicTraits, to storage: NSTextStorage, in range: NSRange) {
        storage.enumerateAttribute(.font, in: range) { value, run, _ in
            guard let font = value as? NSFont else { return }
            let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits))
            if let styled = NSFont(descriptor: descriptor, size: font.pointSize) { storage.addAttribute(.font, value: styled, range: run) }
        }
    }

    /// Wraps or unwraps the selection in `mark`, as an undoable change of the text view. A pill is
    /// not cut: the marks go around its whole run, and the text between them stays as it is.
    static func toggle(_ mark: String, in textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let selection = ComposerPills.expanded(textView.selectedRange(), in: storage)
        let old = textView.string, length = (mark as NSString).length
        let changed = Markdown.toggle(mark, in: old, selection: selection)
        // the marks' places, the later first: the earlier stays where it is.
        let edits: [(NSRange, String)] = (changed.text as NSString).length > (old as NSString).length
            ? [(NSRange(location: NSMaxRange(selection), length: 0), mark), (NSRange(location: selection.location, length: 0), mark)]
            : [(NSRange(location: NSMaxRange(selection), length: length), ""), (NSRange(location: selection.location - length, length: length), "")]
        for (range, text) in edits {
            guard textView.shouldChangeText(in: range, replacementString: text) else { return }
            textView.replaceCharacters(in: range, with: text)
            textView.didChangeText()
        }
        textView.setSelectedRange(changed.selection)
    }
}
