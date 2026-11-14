import LuxCore
import UIKit

struct ChatRowConfiguration: UIContentConfiguration {
    var row: ChatRow
    var images: ImagePipeline?
    /// Words to stand out in the preview: what a search found.
    var highlights: [NSRange] = []

    func makeContentView() -> any UIView & UIContentView { ChatRowView(self) }
    func updated(for state: any UIConfigurationState) -> ChatRowConfiguration { self }
}

/// Avatar, name and time on the first line, the newest message and the unread count under it.
final class ChatRowView: UIView, UIContentView {
    private let avatar = AvatarView()
    private let name = UILabel()
    private let time = UILabel()
    private let preview = UILabel()
    private let badge = BadgeLabel()
    private var current: ChatRowConfiguration
    private var separatorAligned = false

    var configuration: any UIContentConfiguration {
        get { current }
        set { if let new = newValue as? ChatRowConfiguration { apply(new) } }
    }

    init(_ configuration: ChatRowConfiguration) {
        current = configuration
        super.init(frame: .zero)
        name.font = .preferredFont(forTextStyle: .headline)
        time.font = .preferredFont(forTextStyle: .subheadline)
        preview.font = .preferredFont(forTextStyle: .subheadline)
        preview.textColor = .secondaryLabel
        preview.numberOfLines = 2
        for label in [name, time, preview] { label.adjustsFontForContentSizeCategory = true }
        time.setContentCompressionResistancePriority(.required, for: .horizontal)
        time.setContentHuggingPriority(.required, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        for view in [avatar, name, time, preview, badge] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let margins = layoutMarginsGuide
        NSLayoutConstraint.activate([
            avatar.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            avatar.centerYAnchor.constraint(equalTo: centerYAnchor),
            avatar.widthAnchor.constraint(equalToConstant: 52),
            avatar.heightAnchor.constraint(equalToConstant: 52),
            avatar.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 10),
            avatar.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -10),

            name.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 12),
            name.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            time.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 8),
            time.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            time.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),

            preview.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            preview.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 2),
            preview.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -11),
            badge.leadingAnchor.constraint(greaterThanOrEqualTo: preview.trailingAnchor, constant: 8),
            badge.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            badge.topAnchor.constraint(equalTo: preview.topAnchor, constant: 2),
        ])
        // room for two lines of preview keeps every row the same height, as Messages does; one
        // line sits at the top of it.
        let body = UILayoutGuide()
        addLayoutGuide(body)
        let height = body.heightAnchor.constraint(equalToConstant: ceil(preview.font.lineHeight * 2))
        height.priority = .defaultHigh
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: preview.topAnchor),
            body.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -11),
            preview.bottomAnchor.constraint(lessThanOrEqualTo: body.bottomAnchor),
            height,
        ])
        directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
        apply(configuration, force: true)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// The list's separator starts under the name, not under the avatar.
    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        guard !separatorAligned, let cell = sequence(first: superview, next: { $0?.superview }).lazy.compactMap({ $0 as? UICollectionViewListCell }).first else { return }
        cell.separatorLayoutGuide.leadingAnchor.constraint(equalTo: name.leadingAnchor).isActive = true
        separatorAligned = true
    }

    private func apply(_ new: ChatRowConfiguration, force: Bool = false) {
        guard force || new.row != current.row else { return }
        current = new
        let row = new.row
        name.text = row.name
        time.text = TimeText.list(row.date)
        time.textColor = row.isUnread && !row.isMuted ? .tintColor : .secondaryLabel
        if !new.highlights.isEmpty, let font = preview.font {
            let text = NSMutableAttributedString(string: row.preview, attributes: [.font: font, .foregroundColor: UIColor.secondaryLabel])
            for range in new.highlights where NSMaxRange(range) <= text.length {
                text.addAttributes([.foregroundColor: UIColor.label, .font: font.bold], range: range)
            }
            preview.attributedText = text
        } else {
            preview.text = row.preview
        }
        badge.isHidden = !row.isUnread
        badge.text = row.unreadCount > 0 ? String(row.unreadCount) : " "
        badge.backgroundColor = row.isMuted ? .systemGray3 : .tintColor
        avatar.show(row.avatar, name: row.name, members: row.memberAvatars, images: new.images)
        accessibilityLabel = [row.name, row.isUnread ? String(localized: "unread") : nil, row.preview, time.text].compactMap { $0 }.joined(separator: ", ")
        isAccessibilityElement = true
    }
}
