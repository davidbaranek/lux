import LuxCore
import UIKit

/// The members a mention's word offers, above the composer on Liquid Glass of the composer's
/// radius: their picture, name and user id, the best match first, at most four rows tall (the
/// rest scroll). A touched row is a fill concentric with the glass, `gap` in from its edges. A tap
/// puts the member's pill in the composer.
final class MentionSuggestionsView: UIView, UICollectionViewDelegate {
    var onPick: ((MentionSuggestion) -> Void)?
    var images: ImagePipeline?
    /// What shows, in order.
    private(set) var suggestions: [MentionSuggestion] = []
    private static let row: CGFloat = 52
    private static let picture: CGFloat = 32
    /// The composer glass' corner radius, which the list's own glass takes.
    private static let radius: CGFloat = 22
    /// A touched row's gap from the glass' edges, the same all round.
    private static let gap: CGFloat = 6
    private let glass = UIVisualEffectView(effect: UIGlassEffect())
    private lazy var list: UICollectionView = {
        var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
        configuration.backgroundColor = .clear
        configuration.showsSeparators = false
        let list = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: configuration))
        list.backgroundColor = .clear
        list.accessibilityIdentifier = "mention suggestions"
        return list
    }()
    private var dataSource: UICollectionViewDiffableDataSource<Int, MentionSuggestion>?
    private lazy var height = heightAnchor.constraint(equalToConstant: 0)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true
        glass.cornerConfiguration = .uniformCorners(radius: .fixed(Self.radius))
        glass.clipsToBounds = true
        for view in [glass, list] as [UIView] { view.translatesAutoresizingMaskIntoConstraints = false }
        addSubview(glass)
        glass.contentView.addSubview(list)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            list.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor),
            list.topAnchor.constraint(equalTo: glass.contentView.topAnchor),
            list.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor),
            height,
        ])
        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, MentionSuggestion> { [weak self] cell, _, suggestion in
            cell.backgroundConfiguration = .clear()
            cell.configurationUpdateHandler = { [weak self] cell, state in
                guard let cell = cell as? UICollectionViewListCell else { return }
                var content = UIListContentConfiguration.subtitleCell().updated(for: state)
                content.imageProperties.maximumSize = CGSize(width: Self.picture, height: Self.picture)
                content.imageProperties.reservedLayoutSize = CGSize(width: Self.picture, height: Self.picture)
                content.secondaryTextProperties.color = .secondaryLabel
                switch suggestion {
                case .member(let member):
                    content.text = member.name
                    content.secondaryText = member.id
                    content.image = self?.picture(of: member, for: cell)
                case .room:
                    content.text = "@room"
                    content.secondaryText = String(localized: "Notify everyone in this chat")
                    content.image = UIImage(systemName: "megaphone.fill")
                    content.imageProperties.tintColor = .tintColor
                }
                cell.contentConfiguration = content
                // concentric with the glass: the same gap from its edges all round.
                var background = UIBackgroundConfiguration.clear()
                background.backgroundInsets = NSDirectionalEdgeInsets(top: Self.gap, leading: Self.gap, bottom: Self.gap, trailing: Self.gap)
                background.cornerRadius = Self.radius - Self.gap
                if state.isHighlighted || state.isSelected { background.backgroundColor = .tertiarySystemFill }
                cell.backgroundConfiguration = background
            }
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: list) { list, indexPath, suggestion in
            list.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: suggestion)
        }
        list.delegate = self
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Shows `suggestions`; none hides the list.
    func show(_ suggestions: [MentionSuggestion]) {
        guard suggestions != self.suggestions else { return }
        self.suggestions = suggestions
        var snapshot = NSDiffableDataSourceSnapshot<Int, MentionSuggestion>()
        snapshot.appendSections([0])
        snapshot.appendItems(suggestions)
        dataSource?.apply(snapshot, animatingDifferences: false)
        height.constant = CGFloat(min(suggestions.count, 4)) * Self.row
        isHidden = suggestions.isEmpty
        if !suggestions.isEmpty { list.scrollToItem(at: IndexPath(item: 0, section: 0), at: .top, animated: false) }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        guard suggestions.indices.contains(indexPath.item) else { return }
        onPick?(suggestions[indexPath.item])
    }

    /// The member's picture from the cache at once; else their initials, and the row shows the
    /// picture when it has loaded (decoded off the main thread at its size).
    private func picture(of member: ChatMember, for cell: UICollectionViewListCell) -> UIImage? {
        let scale = traitCollection.displayScale, pixels = Int(Self.picture * scale)
        if let ref = member.avatar, let images {
            if let cached = images.cached(ref, pixels: pixels, shape: .circle) {
                return UIImage(cgImage: cached, scale: scale, orientation: .up)
            }
            Task { [weak cell] in
                guard await images.image(ref, pixels: pixels, shape: .circle) != nil else { return }
                cell?.setNeedsUpdateConfiguration()
            }
        }
        return Monogram.image(member.name, side: Self.picture)
    }
}
