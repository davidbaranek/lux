import LuxCore
import UIKit

/// The fonts of a message row at one text size, and how they measure text. UIKit's string
/// measuring is thread-safe, so layouts are made off the main thread with the fonts the cells use.
struct MessageText: TextMeasuring, Sendable {
    let sender: UIFont, author: UIFont, quote: UIFont, body: UIFont, footer: UIFont, reactions: UIFont, fileName: UIFont
    /// A shared post's card: its title, its caption, its "Show more".
    let postTitle: UIFont, postText: UIFont, postMore: UIFont
    /// Code in a message, at the body's size.
    let code: UIFont

    init(_ traits: UITraitCollection) {
        func font(_ style: UIFont.TextStyle) -> UIFont { .preferredFont(forTextStyle: style, compatibleWith: traits) }
        sender = font(.caption1)
        author = font(.subheadline).bold
        quote = font(.footnote)
        body = font(.body)
        footer = font(.caption2)
        reactions = font(.footnote)
        fileName = font(.subheadline).bold
        postTitle = font(.subheadline).bold
        postText = font(.subheadline)
        postMore = font(.subheadline).bold
        code = .monospacedSystemFont(ofSize: body.pointSize * 0.9, weight: .regular)
    }

    func font(_ role: TextRole) -> UIFont {
        switch role {
        case .sender: sender
        case .author: author
        case .reply: quote
        case .quote: quote
        case .body: body
        case .footer: footer
        case .reactions: reactions
        case .fileName: fileName
        case .postTitle: postTitle
        case .postText: postText
        case .postMore: postMore
        }
    }

    func size(of text: String, role: TextRole, width: CGFloat) -> CGSize {
        let font = font(role)
        let rect = (text as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                                  options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                  attributes: [.font: font], context: nil)
        // a quote shows at most two lines.
        // a file's name and a reply's line, one line (they truncate).
        // a post's title, two.
        let height = switch role {
        case .quote, .postTitle: min(rect.height, font.lineHeight * 2)
        case .fileName, .reply: ceil(font.lineHeight)
        default: rect.height
        }
        return CGSize(width: ceil(rect.width), height: ceil(height))
    }

    func size(ofBody message: MessageItem, width: CGFloat) -> CGSize {
        guard !message.styles.isEmpty else { return size(of: message.body, role: .body, width: width) }
        // fixed colours: measuring needs none.
        let rect = bodyText(message, ink: .black, link: .black).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        return CGSize(width: ceil(rect.width), height: ceil(rect.height))
    }

    /// A message's text as the bubble draws it (`MessageStyling`).
    func bodyText(_ message: MessageItem, ink: UIColor, link: UIColor) -> NSAttributedString {
        MessageStyling.body(message, font: body, code: code, ink: ink, link: link)
    }
}
