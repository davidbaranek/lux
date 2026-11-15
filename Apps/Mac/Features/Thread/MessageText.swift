import AppKit
import LuxCore

/// The fonts of a message row, and how they measure text: the same string drawing the row's
/// `TextView`s use, so a measured line is a drawn line. `@unchecked`: its properties are
/// `NSFont`s, which the SDK does not mark `Sendable`; they are immutable and toll-free bridged to
/// `CTFont`, which Core Text documents as safe to use from any thread.
struct MessageText: TextMeasuring, @unchecked Sendable {
    let sender = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
    /// A plain group's sender's name.
    let author = NSFont.systemFont(ofSize: NSFont.systemFontSize + 1, weight: .semibold)
    let quote = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
    let body = NSFont.systemFont(ofSize: NSFont.systemFontSize + 1)
    let footer = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize - 1)
    let reactions = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
    let fileName = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
    /// A shared post's card: its title, its caption, its "Show more".
    let postTitle = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
    let postText = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    let postMore = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
    /// Code in a message, made here: AppKit's font lookups are not for other threads.
    let code = NSFont.monospacedSystemFont(ofSize: (NSFont.systemFontSize + 1) * 0.9, weight: .regular)

    func font(_ role: TextRole) -> NSFont {
        switch role {
        case .sender: sender
        case .author: author
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
                                                  options: TextView.options, attributes: [.font: font])
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        // a quote and a post's title show at most two lines; a file's name, one (it truncates).
        let height = switch role {
        case .quote, .postTitle: min(rect.height, lineHeight * 2)
        case .fileName: lineHeight
        default: rect.height
        }
        return CGSize(width: ceil(rect.width), height: ceil(height))
    }

    func size(ofBody message: MessageItem, width: CGFloat) -> CGSize {
        guard !message.styles.isEmpty else { return size(of: message.body, role: .body, width: width) }
        // fixed colours: measuring needs none, and a system colour must not be resolved off the main thread.
        let rect = bodyText(message, ink: .black, link: .black).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude), options: TextView.options)
        return CGSize(width: ceil(rect.width), height: ceil(rect.height))
    }

    /// A message's text as the bubble draws it (`MessageStyling`).
    func bodyText(_ message: MessageItem, ink: NSColor, link: NSColor) -> NSAttributedString {
        MessageStyling.body(message, font: body, code: code, ink: ink, link: link)
    }
}
