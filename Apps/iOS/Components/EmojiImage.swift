import UIKit

/// Emoji drawn once as images: a menu palette shows images, not titles.
@MainActor
enum EmojiImage {
    private static var cache: [String: UIImage] = [:]

    static func image(_ emoji: String) -> UIImage {
        if let image = cache[emoji] { return image }
        let text = NSAttributedString(string: emoji, attributes: [.font: UIFont.systemFont(ofSize: 28)])
        let size = text.size()
        let image = UIGraphicsImageRenderer(size: size).image { _ in text.draw(at: .zero) }.withRenderingMode(.alwaysOriginal)
        cache[emoji] = image
        return image
    }
}
