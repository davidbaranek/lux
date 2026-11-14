import Foundation

extension Character {
    /// An emoji as people mean it: shown as a picture by default, or made of several scalars
    /// (skin tones, flags, families, a symbol with its emoji variation selector).
    public var isEmoji: Bool {
        guard let first = unicodeScalars.first else { return false }
        return first.properties.isEmojiPresentation || (first.properties.isEmoji && unicodeScalars.count > 1)
    }
}

extension String {
    /// The first emoji in the text, for a reaction picked from a keyboard or a character palette.
    public var firstEmoji: String? { first(where: \.isEmoji).map(String.init) }
}
