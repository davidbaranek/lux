import LuxCore
import UIKit

/// "Anna is typing…" with the typists' pictures (up to three, overlapping), above the composer.
final class TypingView: UIView {
    private static let side: CGFloat = 20
    private let avatars = (0..<3).map { _ in AvatarView() }
    private let label = UILabel()
    private let stack = UIStackView()
    /// A glass capsule behind the line: it stays legible over the messages it floats on.
    private let glass = UIVisualEffectView(effect: UIGlassEffect())
    var images: ImagePipeline?

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .preferredFont(forTextStyle: .caption1)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        let faces = UIStackView(arrangedSubviews: avatars)
        faces.spacing = -6
        for avatar in avatars {
            avatar.side = Self.side
            avatar.clipsToBounds = true
            avatar.layer.borderWidth = 1.5
            avatar.layer.borderColor = UIColor.systemBackground.cgColor
            avatar.widthAnchor.constraint(equalToConstant: Self.side).isActive = true
            avatar.heightAnchor.constraint(equalToConstant: Self.side).isActive = true
        }
        stack.addArrangedSubview(faces)
        stack.addArrangedSubview(label)
        stack.spacing = 6
        stack.alignment = .center
        glass.cornerConfiguration = .capsule()
        for view in [glass, stack] as [UIView] { view.translatesAutoresizingMaskIntoConstraints = false }
        addSubview(glass)
        glass.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -4),
        ])
        isAccessibilityElement = true
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            for avatar in self.avatars { avatar.layer.borderColor = UIColor.systemBackground.cgColor }
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Keeps the last typists while it fades out, so the line does not empty before it goes.
    func show(_ typists: [Typist]) {
        guard let text = TypingText.text(typists.map(\.name)) else { return }
        label.text = text
        accessibilityLabel = text
        for (index, avatar) in avatars.enumerated() {
            avatar.isHidden = index >= typists.count
            if index < typists.count { avatar.show(typists[index].avatar, name: typists[index].name, images: images) }
        }
    }
}
