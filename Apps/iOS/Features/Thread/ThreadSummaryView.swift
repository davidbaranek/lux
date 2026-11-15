import LuxCore
import UIKit

/// Under a Matrix thread's root: who replied, how many, and the last reply, in a rounded box; a
/// dot in the accent colour while some replies are unread. A tap opens the thread. Its parts go
/// where the message's layout measured them (`MessageLayout.thread`).
final class ThreadSummaryView: UIControl {
    private var avatars: [AvatarView] = []
    private let label = UILabel()
    private let dot = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .tertiarySystemFill
        layer.cornerRadius = 10
        layer.cornerCurve = .continuous
        label.lineBreakMode = .byTruncatingTail
        label.isUserInteractionEnabled = false
        dot.backgroundColor = .tintColor
        dot.isUserInteractionEnabled = false
        addSubview(label)
        addSubview(dot)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityHint = String(localized: "Opens the thread")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted ? .quaternaryLabel : .tertiarySystemFill }
    }

    func show(_ message: MessageItem, layout: MessageLayout, font: UIFont, images: ImagePipeline?) {
        guard let summary = message.thread else { return }
        while avatars.count < layout.threadAvatars.count {
            let avatar = AvatarView()
            avatar.isUserInteractionEnabled = false
            // a ring of the box's ground sets each picture apart from the one under it.
            avatar.layer.borderWidth = 1.5
            insertSubview(avatar, at: 0)
            avatars.append(avatar)
        }
        for (index, avatar) in avatars.enumerated() {
            avatar.isHidden = index >= layout.threadAvatars.count
            guard index < layout.threadAvatars.count else { continue }
            let participant = summary.participants[index]
            avatar.side = layout.threadAvatars[index].width
            avatar.frame = layout.threadAvatars[index]
            avatar.layer.borderColor = UIColor.systemBackground.cgColor
            avatar.show(participant.avatar, name: participant.name, images: images)
            // the last to reply on top.
            bringSubviewToFront(avatars[layout.threadAvatars.count - 1 - index])
        }
        label.frame = layout.threadText ?? .zero
        let words = NSMutableAttributedString(string: summary.countText, attributes: [.font: font.bold, .foregroundColor: UIColor.tintColor])
        if let latest = summary.latestReplyText {
            words.append(NSAttributedString(string: " · " + latest, attributes: [.font: font, .foregroundColor: UIColor.secondaryLabel]))
        }
        label.attributedText = words
        dot.isHidden = layout.threadDot == nil
        if let frame = layout.threadDot {
            dot.frame = frame
            dot.layer.cornerRadius = frame.width / 2
        }
        accessibilityLabel = [summary.text, summary.unread > 0 ? String(localized: "\(summary.unread) unread") : nil]
            .compactMap { $0 }.joined(separator: ", ")
    }
}
