import LuxCore
import UIKit

/// What a search found: "Conversations", "Photos" (a grid of thumbnails), then "Messages", in
/// the chat list's own row.
final class SearchResultsViewController: UIViewController, UICollectionViewDelegate {
    enum Section: Int { case chats, photos, messages }

    private let images: ImagePipeline?
    /// Opens a chat; at the message found, for a found message.
    private let open: (ChatRow, _ focusEvent: String?) -> Void
    private var rows: [String: ChatRow] = [:]
    private var chats: [String: ChatRow] = [:]
    private var highlights: [String: [NSRange]] = [:]
    private var photos: [String: FoundPhoto] = [:]
    /// While the index is still reading chats, one small line over the results: they are what it
    /// has so far. (The search field is at the bottom, so the line is at the top.)
    private let status = UILabel()
    private var progress: SearchIndexer.Progress?
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, String>!

    init(images: ImagePipeline?, open: @escaping (ChatRow, _ focusEvent: String?) -> Void) {
        self.images = images
        self.open = open
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        var list = UICollectionLayoutListConfiguration(appearance: .plain)
        list.headerMode = .supplementary
        let layout = UICollectionViewCompositionalLayout { [weak self] index, environment in
            guard self?.dataSource.sectionIdentifier(for: index) == .photos else {
                return NSCollectionLayoutSection.list(using: list, layoutEnvironment: environment)
            }
            return Self.photoGrid(width: environment.container.effectiveContentSize.width)
        }
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.keyboardDismissMode = .onDrag
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "search-results"
        view.addSubview(collectionView)
        // what scrolls under the bar blurs out gradually, not at a hard edge (the system's default).
        collectionView.topEdgeEffect.style = .soft
        status.font = .preferredFont(forTextStyle: .caption2)
        status.adjustsFontForContentSizeCategory = true
        status.textColor = .tertiaryLabel
        status.textAlignment = .center
        status.isHidden = true
        status.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(status)
        NSLayoutConstraint.activate([
            status.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            status.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 2),
        ])

        let images = images
        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, _, id in
            guard let row = self?.rows[id] else { return }
            cell.contentConfiguration = ChatRowConfiguration(row: row, images: images, highlights: self?.highlights[id] ?? [])
        }
        let photo = UICollectionView.CellRegistration<PhotoCell, String> { [weak self] cell, _, id in
            guard let found = self?.photos[id] else { return }
            cell.show(found, images: images)
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) {
            [weak self] header, _, indexPath in
            var content = header.defaultContentConfiguration()
            content.text = switch self?.dataSource.sectionIdentifier(for: indexPath.section) {
            case .chats: String(localized: "Conversations")
            case .photos: String(localized: "Photos")
            case .messages, nil: String(localized: "Messages")
            }
            header.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { [weak self] collectionView, indexPath, id in
            self?.dataSource.sectionIdentifier(for: indexPath.section) == .photos
                ? collectionView.dequeueConfiguredReusableCell(using: photo, for: indexPath, item: id)
                : collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: id)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
        showProgress(progress)
    }

    func show(_ hits: SearchHits) {
        guard isViewLoaded else { return }
        let found = hits.messages.map(\.row)
        rows = Dictionary((hits.chats + found).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        chats = Dictionary(hits.messages.map { ($0.id, $0.chat) }, uniquingKeysWith: { first, _ in first })
        highlights = Dictionary(hits.messages.map { ($0.id, $0.previewMatches) }, uniquingKeysWith: { first, _ in first })
        photos = Dictionary(hits.photos.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var snapshot = NSDiffableDataSourceSnapshot<Section, String>()
        if !hits.chats.isEmpty {
            snapshot.appendSections([.chats])
            snapshot.appendItems(hits.chats.map(\.id), toSection: .chats)
        }
        // a photo's id is its event's, which no chat or message row has.
        let shownPhotos = hits.photos.map(\.id).filter { rows[$0] == nil }
        if !shownPhotos.isEmpty {
            snapshot.appendSections([.photos])
            snapshot.appendItems(shownPhotos, toSection: .photos)
        }
        let messages = found.map(\.id).filter { !hits.chats.map(\.id).contains($0) }
        if !messages.isEmpty {
            snapshot.appendSections([.messages])
            snapshot.appendItems(messages, toSection: .messages)
        }
        dataSource.applySnapshotUsingReloadData(snapshot)
    }

    /// The index's note while it is not complete; nothing once it is. The results start under it.
    func showProgress(_ progress: SearchIndexer.Progress?) {
        // kept for when the results first show: the index may report before search opens.
        self.progress = progress
        guard isViewLoaded else { return }
        let note = progress?.note
        status.text = note
        status.isHidden = note == nil
        let top: CGFloat = note == nil ? 0 : status.intrinsicContentSize.height + 4
        if collectionView.contentInset.top != top { collectionView.contentInset.top = top }
    }

    /// The found photos as a grid of square thumbnails, about 100 points each, as Photos shows
    /// them.
    private static func photoGrid(width: CGFloat) -> NSCollectionLayoutSection {
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
        section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 12, trailing: 0)
        section.boundarySupplementaryItems = [NSCollectionLayoutBoundarySupplementaryItem(
            layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(36)),
            elementKind: UICollectionView.elementKindSectionHeader, alignment: .top)]
        return section
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return }
        // a found message's or photo's id is its event's: its chat opens there.
        if let photo = photos[id] {
            open(photo.chat, id)
        } else if let chat = chats[id] {
            open(chat, id)
        } else if let chat = rows[id] {
            open(chat, nil)
        }
    }
}

/// A found photo's thumbnail, square, filled.
private final class PhotoCell: UICollectionViewCell {
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
