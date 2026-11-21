import LuxCore
#if canImport(UIKit)
import UIKit
typealias PlatformFont = UIFont
typealias PlatformColor = UIColor
#else
import AppKit
typealias PlatformFont = NSFont
typealias PlatformColor = NSColor
#endif

/// A message's text as both apps' bubbles draw it: its formatting, then its links underlined.
/// The layouts measure the same string, so a measured line is a drawn line. Thread-safe with
/// fonts made beforehand (AppKit's font lookups are not for other threads).
enum MessageStyling {
    static func body(_ message: MessageItem, font: PlatformFont, code: PlatformFont, ink: PlatformColor,
                     link: PlatformColor) -> NSAttributedString {
        let text = NSMutableAttributedString(string: message.body, attributes: [.font: font, .foregroundColor: ink])
        let length = text.length
        for style in message.styles where NSMaxRange(style.range) <= length {
            let range = style.range
            switch style.kind {
            case .bold: add(.bold, to: text, in: range)
            case .italic: add(.italic, to: text, in: range)
            case .underline: text.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            case .strikethrough: text.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            case .code, .codeBlock:
                text.addAttributes([.font: code, .backgroundColor: ink.withAlphaComponent(0.1)], range: range)
            case .quote:
                let paragraph = NSMutableParagraphStyle()
                paragraph.firstLineHeadIndent = 10
                paragraph.headIndent = 10
                text.addAttributes([.paragraphStyle: paragraph, .foregroundColor: ink.withAlphaComponent(0.7)], range: range)
            case .link: break
            case .mention:
                // a pill: its name bold, on a tint of the link's colour (white on the account's own bubble).
                add(.bold, to: text, in: range)
                text.addAttributes([.foregroundColor: link, .backgroundColor: link.withAlphaComponent(0.18)], range: range)
            }
        }
        for found in message.links where NSMaxRange(found.range) <= length {
            text.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: link], range: found.range)
        }
        return text
    }

    /// The member a pill at `index` of a message's text names, if one is there.
    static func mentionedUser(at index: Int, in message: MessageItem) -> String? {
        for style in message.styles where NSLocationInRange(index, style.range) {
            if case .mention(.user(let userId)) = style.kind { return userId }
        }
        return nil
    }

    /// A message that mentions the account: its bubble (or a plain row's band) takes this tint.
    static let mentionTint = PlatformColor.systemOrange

    private enum Emphasis { case bold, italic }

    /// Makes every font run in `range` bold or italic as well, where its family has that face.
    private static func add(_ emphasis: Emphasis, to text: NSMutableAttributedString, in range: NSRange) {
        text.enumerateAttribute(.font, in: range) { value, run, _ in
            guard let font = value as? PlatformFont, let emphasized = emphasized(font, emphasis) else { return }
            text.addAttribute(.font, value: emphasized, range: run)
        }
    }

    private static func emphasized(_ font: PlatformFont, _ emphasis: Emphasis) -> PlatformFont? {
        let descriptor = font.fontDescriptor
        #if canImport(UIKit)
        let trait: UIFontDescriptor.SymbolicTraits = emphasis == .bold ? .traitBold : .traitItalic
        return descriptor.withSymbolicTraits(descriptor.symbolicTraits.union(trait)).map { UIFont(descriptor: $0, size: font.pointSize) }
        #else
        let trait: NSFontDescriptor.SymbolicTraits = emphasis == .bold ? .bold : .italic
        return NSFont(descriptor: descriptor.withSymbolicTraits(descriptor.symbolicTraits.union(trait)), size: font.pointSize)
        #endif
    }
}
