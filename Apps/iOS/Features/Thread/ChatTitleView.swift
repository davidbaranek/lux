import LuxCore
import UIKit

/// A chat's title in the top bar: its picture, its name and under it the networks, in a Liquid
/// Glass capsule, as Messages shows a conversation's.
final class ChatTitleView: UIView {
    private static let pictureSide: CGFloat = 30
    private let glass = UIVisualEffectView(effect: UIGlassEffect())
    private let picture = AvatarView()
    private let name = UILabel()
    private let detail = UILabel()

    init(row: ChatRow, images: ImagePipeline?) {
        super.init(frame: .zero)
        glass.cornerConfiguration = .capsule()
        picture.side = Self.pictureSide
        picture.show(row.avatar, name: row.name, members: row.memberAvatars, images: images)
        name.text = row.name
        name.font = .preferredFont(forTextStyle: .subheadline).bold
        name.adjustsFontForContentSizeCategory = true
        detail.font = .preferredFont(forTextStyle: .caption1)
        detail.adjustsFontForContentSizeCategory = true
        detail.textColor = .secondaryLabel
        detail.isHidden = true
        let lines = UIStackView(arrangedSubviews: [name, detail])
        lines.axis = .vertical
        let stack = UIStackView(arrangedSubviews: [picture, lines])
        stack.spacing = 8
        stack.alignment = .center
        for view in [glass, stack] as [UIView] { view.translatesAutoresizingMaskIntoConstraints = false }
        addSubview(glass)
        glass.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            // as tall as the bar's round buttons (back, networks).
            glass.heightAnchor.constraint(equalToConstant: 44),
            picture.widthAnchor.constraint(equalToConstant: Self.pictureSide),
            picture.heightAnchor.constraint(equalToConstant: Self.pictureSide),
            stack.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 7),
            stack.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -14),
            stack.centerYAnchor.constraint(equalTo: glass.contentView.centerYAnchor),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .header
        updateAccessibility()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// The networks a merged chat shows (one, or all of them); nil hides the line.
    var subtitle: String? {
        get { detail.text }
        set {
            detail.text = newValue
            detail.isHidden = newValue == nil
            updateAccessibility()
        }
    }

    private func updateAccessibility() {
        accessibilityLabel = [name.text, detail.text].compactMap { $0 }.joined(separator: ", ")
    }
}
