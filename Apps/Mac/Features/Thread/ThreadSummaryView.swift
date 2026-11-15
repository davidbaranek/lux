import AppKit
import LuxCore

/// Under a Matrix thread's root: who replied, how many, and the last reply, in a rounded box; a
/// dot in the accent colour while some replies are unread. A click opens the thread beside the
/// chat. Its parts go where the message's layout measured them (`MessageLayout.thread`).
final class ThreadSummaryView: NSView {
    private var avatars: [AvatarView] = []
    private let label = TextView()
    private let dot = FlippedView()
    var onClick: (() -> Void)?
    /// The place's colour: the count and the unread dot.
    var accent = NSColor.controlAccentColor

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        dot.wantsLayer = true
        addSubview(label)
        addSubview(dot)
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    @objc private func clicked() { onClick?() }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return onClick != nil
    }

    /// The pointing hand: it opens something.
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    func show(_ message: MessageItem, layout: MessageLayout, font: NSFont, images: ImagePipeline?) {
        guard let summary = message.thread else { return }
        layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.12).cgColor
        while avatars.count < layout.threadAvatars.count, let side = layout.threadAvatars.first?.width {
            let avatar = AvatarView(side: side)
            avatar.wantsLayer = true
            avatar.layer?.borderWidth = 1.5
            addSubview(avatar, positioned: .below, relativeTo: label)
            avatars.append(avatar)
        }
        for (index, avatar) in avatars.enumerated() {
            avatar.isHidden = index >= layout.threadAvatars.count
            guard index < layout.threadAvatars.count else { continue }
            let participant = summary.participants[index]
            avatar.frame = layout.threadAvatars[index]
            avatar.layer?.borderColor = NSColor.windowBackgroundColor.cgColor
            avatar.show(participant.avatar, name: participant.name, images: images)
        }
        // the last to reply on top.
        for avatar in avatars.prefix(layout.threadAvatars.count).reversed() {
            addSubview(avatar, positioned: .below, relativeTo: label)
        }
        label.frame = layout.threadText ?? .zero
        let truncated = NSMutableParagraphStyle()
        truncated.lineBreakMode = .byTruncatingTail
        let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        let words = NSMutableAttributedString(string: summary.countText,
                                              attributes: [.font: bold, .foregroundColor: accent, .paragraphStyle: truncated])
        if let latest = summary.latestReplyText {
            words.append(NSAttributedString(string: " · " + latest,
                                            attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: truncated]))
        }
        label.set(words)
        dot.isHidden = layout.threadDot == nil
        if let frame = layout.threadDot {
            dot.frame = frame
            dot.layer?.cornerRadius = frame.width / 2
            dot.layer?.backgroundColor = accent.cgColor
        }
        setAccessibilityLabel([summary.text, summary.unread > 0 ? String(localized: "\(summary.unread) unread") : nil]
            .compactMap { $0 }.joined(separator: ", "))
        window?.invalidateCursorRects(for: self)
    }
}
