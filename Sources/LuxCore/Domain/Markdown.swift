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

    /// Wraps the selection in `mark` (`**`, `*`, `~~`, `` ` ``), or takes the mark away when the
    /// selection already has it on both sides. With nothing selected, it puts the two marks in
    /// with the cursor between them. Returns the new text and selection.
    public static func toggle(_ mark: String, in text: String, selection: NSRange) -> (text: String, selection: NSRange) {
        let string = text as NSString
        let length = (mark as NSString).length
        let before = NSRange(location: selection.location - length, length: length)
        let after = NSRange(location: NSMaxRange(selection), length: length)
        if before.location >= 0, NSMaxRange(after) <= string.length,
           string.substring(with: before) == mark, string.substring(with: after) == mark {
            let inner = string.substring(with: selection)
            let changed = string.replacingCharacters(in: NSRange(location: before.location, length: selection.length + 2 * length), with: inner)
            return (changed, NSRange(location: before.location, length: selection.length))
        }
        let inner = string.substring(with: selection)
        let changed = string.replacingCharacters(in: selection, with: mark + inner + mark)
        return (changed, NSRange(location: selection.location + length, length: selection.length))
    }

    /// The marks the Format menus offer.
    public static let boldMark = "**", italicMark = "*", strikethroughMark = "~~", codeMark = "`"
}
