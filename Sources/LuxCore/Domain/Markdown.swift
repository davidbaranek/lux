import Foundation

/// The Markdown a user writes in the composer: where its formatting is, so the composer can show
/// it as it is typed (`runs(in:)`, read by the core with the parser sending uses, so what the
/// composer shows is what the others get), and wrapping a selection in a mark.
public enum Markdown {
    public enum Kind: Hashable, Sendable {
        case bold, italic, strikethrough, code, codeBlock, quote
        /// The marks themselves (`**`, `` ` ``, `> `): shown, but dimmed.
        case mark
    }

    public struct Run: Hashable, Sendable {
        public var kind: Kind
        /// In UTF-16 offsets, as text views count.
        public var range: NSRange
    }

    /// One change a toggle makes: `range` of the text before it gives way to `replacement`.
    public struct Edit: Hashable, Sendable {
        public var range: NSRange
        public var replacement: String
    }

    /// Wraps the selection in `mark` (`**`, `*`, `~~`, `` ` ``), or takes the mark away when the
    /// selection already has it on both sides. With nothing selected, it puts the two marks in
    /// with the cursor between them. The edits are only the marks, the later first (each range is
    /// in the text as the edits before it left it), so a text view applies them one by one and
    /// what is between them (a pill, its undo) stays as it is; and the selection after them.
    public static func toggleEdits(_ mark: String, in text: String, selection: NSRange) -> (edits: [Edit], selection: NSRange) {
        let string = text as NSString
        let length = (mark as NSString).length
        let before = NSRange(location: selection.location - length, length: length)
        let after = NSRange(location: NSMaxRange(selection), length: length)
        if before.location >= 0, NSMaxRange(after) <= string.length,
           string.substring(with: before) == mark, string.substring(with: after) == mark {
            return ([Edit(range: after, replacement: ""), Edit(range: before, replacement: "")],
                    NSRange(location: before.location, length: selection.length))
        }
        return ([Edit(range: NSRange(location: NSMaxRange(selection), length: 0), replacement: mark),
                 Edit(range: NSRange(location: selection.location, length: 0), replacement: mark)],
                NSRange(location: selection.location + length, length: selection.length))
    }

    /// `toggleEdits` applied to `text`: the new text and selection.
    public static func toggle(_ mark: String, in text: String, selection: NSRange) -> (text: String, selection: NSRange) {
        let toggled = toggleEdits(mark, in: text, selection: selection)
        let changed = toggled.edits.reduce(text as NSString) { $0.replacingCharacters(in: $1.range, with: $1.replacement) as NSString }
        return (changed as String, toggled.selection)
    }

    /// The marks the Format menus offer.
    public static let boldMark = "**", italicMark = "*", strikethroughMark = "~~", codeMark = "`"
}
