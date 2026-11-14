import LuxCore
import UIKit

/// A pinned chat in the grid above the inbox, as Messages pins conversations: a large picture,
/// the name under it, and a dot while it has unread messages. Laid out by hand.
final class PinnedChatCell: UICollectionViewCell {
    static let side: CGFloat = 64
    private let avatar = AvatarView()
    private let name = UILabel()
    private let dot = UIView()
    private var shown: ChatRow?

    override init(frame: CGRect) {
        super.init(frame: frame)
        avatar.side = Self.side
        name.font = .preferredFont(forTextStyle: .caption1)
        name.adjustsFontForContentSizeCategory = true
        name.textAlignment = .center
        name.lineBreakMode = .byTruncatingTail
        dot.backgroundColor = .systemBlue
        dot.layer.cornerRadius = 6
        dot.layer.borderWidth = 2
        dot.layer.borderColor = UIColor.systemBackground.cgColor
        for view in [avatar, name, dot] { contentView.addSubview(view) }
        isAccessibilityElement = true
        accessibilityTraits = .button
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            self.dot.layer.borderColor = UIColor.systemBackground.cgColor
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let x = (bounds.width - Self.side) / 2
        avatar.frame = CGRect(x: x, y: 4, width: Self.side, height: Self.side)
        dot.frame = CGRect(x: x + Self.side - 14, y: 4, width: 12, height: 12)
        let height = ceil(name.font.lineHeight)
        name.frame = CGRect(x: 0, y: avatar.frame.maxY + 6, width: bounds.width, height: height)
    }

    func show(_ row: ChatRow, images: ImagePipeline?) {
        guard row != shown else { return }
        shown = row
        avatar.show(row.avatar, name: row.name, members: row.memberAvatars, images: images)
        name.text = row.name
        name.font = row.isUnread ? .preferredFont(forTextStyle: .caption1).bold : .preferredFont(forTextStyle: .caption1)
        dot.isHidden = !row.isUnread || row.isMuted
        accessibilityLabel = row.name
        accessibilityValue = row.isUnread ? String(localized: "Unread") : nil
    }

    override var isHighlighted: Bool {
        didSet { UIView.animate(withDuration: 0.15) { self.avatar.alpha = self.isHighlighted ? 0.6 : 1 } }
    }
}
