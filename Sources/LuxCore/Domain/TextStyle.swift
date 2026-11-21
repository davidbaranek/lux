import Foundation

/// A run of formatting in a message's text, in UTF-16 offsets (as text views count).
public struct TextStyle: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case bold, italic, underline, strikethrough
        /// Code inside a line.
        case code
        /// A block of code: its own lines, spaces kept.
        case codeBlock
        case quote
        case link(URL)
        /// A pill: a member (shown with their name in the room now) or `@room`.
        case mention(MentionTarget)
    }

    public var kind: Kind
    public var range: NSRange

    public init(_ kind: Kind, _ range: NSRange) {
        self.kind = kind
        self.range = range
    }
}
