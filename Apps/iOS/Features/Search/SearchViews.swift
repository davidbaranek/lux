import LuxCore
import UIKit

/// What search's results and its lists of one kind share: the photo grid and its cells, the rows
/// of links, files and threads, the kinds' buttons and the note that the look is still looked for.
@MainActor
enum SearchViews {
    /// Photos as a grid of square thumbnails, about 100 points each, as Photos shows them.
    static func photoGrid(width: CGFloat, header: Bool) -> NSCollectionLayoutSection {
        let spacing: CGFloat = 2
        let columns = max(3, Int((width / 100).rounded()))
        let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1 / CGFloat(columns)),
                                                            heightDimension: .fractionalHeight(1)))
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .fractionalWidth(1 / CGFloat(columns))),
            repeatingSubitem: item, count: columns)
        group.interItemSpacing = .fixed(spacing)
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = spacing
        section.contentInsets = .zero
        if header {
            let item = NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(36)),
                elementKind: UICollectionView.elementKindSectionHeader, alignment: .top)
            // level with the list sections' headers (a list's margins are 16 points, a grid's 8).
            item.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8)
            section.boundarySupplementaryItems = [item]
        }
        return section
    }

    /// How many photos a row of the grid holds at `width`: the results show two rows.
    static func photoColumns(width: CGFloat) -> Int { max(3, Int((width / 100).rounded())) }

    static func link(_ link: FoundLink) -> UIListContentConfiguration {
        var content = UIListContentConfiguration.subtitleCell()
        content.image = UIImage(systemName: "link")
        content.imageProperties.tintColor = .secondaryLabel
        content.text = link.host
        content.secondaryText = "\(link.chat.name) · \(link.text)"
        content.secondaryTextProperties.numberOfLines = 2
        content.secondaryTextProperties.color = .secondaryLabel
        return content
    }

    static func file(_ file: FoundFile) -> UIListContentConfiguration {
        var content = UIListContentConfiguration.subtitleCell()
        content.image = UIImage(systemName: symbol(of: file))
        content.imageProperties.tintColor = .secondaryLabel
        content.text = file.name
        content.secondaryText = "\(file.chat.name) · \(file.detail)"
        content.secondaryTextProperties.color = .secondaryLabel
        return content
    }

    static func thread(_ thread: FoundThread) -> UIListContentConfiguration {
        var content = UIListContentConfiguration.subtitleCell()
        content.image = UIImage(systemName: "bubble.left.and.text.bubble.right")
        content.imageProperties.tintColor = .secondaryLabel
        content.text = thread.title
        content.textProperties.numberOfLines = 2
        content.secondaryText = "\(thread.chat.name) · \(thread.detail)"
        content.secondaryTextProperties.numberOfLines = 2
        content.secondaryTextProperties.color = .secondaryLabel
        return content
    }

    /// A link's menu: its message in its chat, or a copy of the address.
    static func menu(for link: FoundLink, open: @escaping @MainActor (SearchTarget) -> Void) -> UIContextMenuConfiguration {
        UIContextMenuConfiguration(actionProvider: { _ in
            UIMenu(children: [
                UIAction(title: String(localized: "Show in Chat"), image: UIImage(systemName: "bubble.left")) { _ in
                    open(link.message)
                },
                UIAction(title: String(localized: "Copy Link"), image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.string = link.url
                },
            ])
        })
    }

    /// A file's symbol by its type: a document, a sound, a film, an archive.
    static func symbol(of file: FoundFile) -> String {
        let type = file.mimetype ?? ""
        if type.hasPrefix("audio/") { return "music.note" }
        if type.hasPrefix("video/") { return "film" }
        if type.contains("pdf") { return "doc.richtext" }
        if type.contains("zip") || type.contains("compressed") { return "doc.zipper" }
        return "doc"
    }
}

/// A found photo's thumbnail, square, filled.
final class SearchPhotoCell: UICollectionViewCell {
    private let picture = UIImageView()
    private var shown: ImageRef?

    override init(frame: CGRect) {
        super.init(frame: frame)
        picture.contentMode = .scaleAspectFill
        picture.clipsToBounds = true
        picture.backgroundColor = .secondarySystemFill
        picture.frame = contentView.bounds
        picture.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(picture)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(_ photo: FoundPhoto, images: ImagePipeline?) {
        let ref = photo.image
        shown = ref
        accessibilityLabel = String(localized: "Photo from \(photo.isOwn ? String(localized: "you") : photo.senderName) in \(photo.chat.name)")
        let pixels = Int(bounds.width * traitCollection.displayScale)
        if let cached = images?.cached(ref, pixels: pixels) {
            picture.image = UIImage(cgImage: cached)
            return
        }
        picture.image = nil
        Task { [weak self] in
            guard let image = await images?.image(ref, pixels: pixels), self?.shown == ref else { return }
            self?.picture.image = UIImage(cgImage: image)
        }
    }
}

/// A section's title, and "Show All" when more of its kind are found than it shows.
final class SearchSectionHeader: UICollectionReusableView {
    private let title = UILabel()
    private let showAll = UIButton(configuration: .plain())
    private var action: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        title.font = .preferredFont(forTextStyle: .headline)
        title.adjustsFontForContentSizeCategory = true
        title.accessibilityTraits = .header
        var button = UIButton.Configuration.plain()
        button.title = String(localized: "Show All")
        button.contentInsets = .zero
        showAll.configuration = button
        showAll.addAction(UIAction { [weak self] _ in self?.action?() }, for: .primaryActionTriggered)
        let row = UIStackView(arrangedSubviews: [title, UIView(), showAll])
        row.alignment = .firstBaseline
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(_ text: String, showAll action: (() -> Void)?) {
        title.text = text
        self.action = action
        showAll.isHidden = action == nil
    }
}

/// The kinds' buttons over the results: Liquid Glass, the four side by side across the width (each
/// its symbol over its name, so all fit a phone), each opening its kind's list.
final class SearchKindButtons: UIView {
    var onOpen: ((SearchKind) -> Void)?

    init() {
        super.init(frame: .zero)
        let row = UIStackView(arrangedSubviews: SearchKind.allCases.map { kind in
            var configuration = UIButton.Configuration.glass()
            configuration.title = kind.title
            configuration.image = UIImage(systemName: kind.symbol)
            configuration.imagePlacement = .top
            configuration.imagePadding = 4
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 4, bottom: 8, trailing: 4)
            configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .body)
            configuration.titleLineBreakMode = .byTruncatingTail
            configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
                var attributes = $0
                attributes.font = .preferredFont(forTextStyle: .caption1).withWeight(.semibold)
                return attributes
            }
            configuration.background.cornerRadius = 16
            let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in self?.onOpen?(kind) })
            button.accessibilityIdentifier = "search-kind-\(kind.rawValue)"
            return button
        })
        row.spacing = 8
        row.distribution = .fillEqually
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

/// "Looking for photos by what they show…" with a spinner, in a Liquid Glass capsule, while the
/// text encoder loads: the photos found by their look follow.
final class LookingNote: UIVisualEffectView {
    private let spinner = UIActivityIndicatorView(style: .medium)

    init() {
        super.init(effect: UIGlassEffect())
        cornerConfiguration = .capsule()
        let label = UILabel()
        label.text = String(localized: "Looking for photos by what they show…")
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        let row = UIStackView(arrangedSubviews: [spinner, label])
        row.spacing = 10
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
        ])
        isAccessibilityElement = true
        accessibilityLabel = label.text
        accessibilityTraits = .updatesFrequently
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Shown with its spinner turning, or gone.
    var isShown: Bool {
        get { !isHidden }
        set {
            if newValue { spinner.startAnimating() } else { spinner.stopAnimating() }
            isHidden = !newValue
            alpha = newValue ? 1 : 0
        }
    }
}

extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        UIFont(descriptor: fontDescriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight]]), size: 0)
    }
}
