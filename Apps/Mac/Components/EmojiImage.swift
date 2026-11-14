import AppKit

@MainActor
enum EmojiImage {
    private static var cache: [String: NSImage] = [:]

    static func image(_ emoji: String) -> NSImage {
        if let image = cache[emoji] { return image }
        let text = NSAttributedString(string: emoji, attributes: [.font: NSFont.systemFont(ofSize: 18)])
        let image = NSImage(size: text.size(), flipped: false) { rect in text.draw(in: rect); return true }
        cache[emoji] = image
        return image
    }
}
