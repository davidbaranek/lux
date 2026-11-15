import LuxCore
import QuickLook
import UIKit

/// What a chat shared, the newest first, read back as the user scrolls: photos and videos in a
/// grid of squares (as Photos and Messages show them), files and links as rows. The kinds switch
/// in the bar, and the search field keeps those that hold its words (photos also by the words in
/// them and how they look, from photo search). A photo, video or file opens in Quick Look, a link
/// in the browser.
final class SharedViewController: UIViewController, UICollectionViewDelegate, UISearchResultsUpdating,
    @MainActor QLPreviewControllerDataSource {
    private let details: ChatDetailsModel
    private let images: ImagePipeline?
    private var models: [SharedKind: SharedModel] = [:]
    private var kind: SharedKind
    private var observation: AnyObject?
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private var items: [String: SharedItem] = [:]
    private let empty = UILabel()
    private let loading = UIActivityIndicatorView(style: .medium)
    private var previewed: URL?
    private lazy var kinds = UISegmentedControl(items: SharedKind.allCases.map(\.title))
    private let search = UISearchController(searchResultsController: nil)

    private var model: SharedModel {
        if let model = models[kind] { return model }
        let model = details.shared(kind)
        models[kind] = model
        return model
    }

    init(details: ChatDetailsModel, kind: SharedKind, images: ImagePipeline?) {
        self.details = details
        self.kind = kind
        self.images = images
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.largeTitleDisplayMode = .never
        kinds.selectedSegmentIndex = SharedKind.allCases.firstIndex(of: kind) ?? 0
        kinds.addAction(UIAction { [weak self] _ in self?.switchKind() }, for: .valueChanged)
        navigationItem.titleView = kinds
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false

        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout())
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.delegate = self
        collectionView.keyboardDismissMode = .onDrag
        collectionView.topEdgeEffect.style = .soft
        collectionView.accessibilityIdentifier = "shared"
        view.addSubview(collectionView)

        let images = images
        let tile = UICollectionView.CellRegistration<SharedTile, SharedItem> { cell, _, item in cell.show(item, images: images) }
        let row = UICollectionView.CellRegistration<UICollectionViewListCell, SharedItem> { cell, _, item in
            var content = UIListContentConfiguration.subtitleCell()
            switch item.content {
            case .file(let name, let size, _):
                content.image = UIImage(systemName: "doc.fill")
                content.text = name
                content.secondaryText = [size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) },
                                         item.senderName, item.date.formatted(date: .abbreviated, time: .omitted)]
                    .compactMap { $0 }.joined(separator: " · ")
            case .link(let url, let text):
                content.image = UIImage(systemName: "link")
                content.text = url.shownAddress
                content.secondaryText = text
                content.secondaryTextProperties.numberOfLines = 2
            case .photo, .video:
                break
            }
            content.textProperties.numberOfLines = 1
            content.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { [weak self] collectionView, indexPath, id in
            guard let item = self?.items[id] else { return nil }
            return item.content.isMedia
                ? collectionView.dequeueConfiguredReusableCell(using: tile, for: indexPath, item: item)
                : collectionView.dequeueConfiguredReusableCell(using: row, for: indexPath, item: item)
        }
        empty.font = .preferredFont(forTextStyle: .body)
        empty.textColor = .secondaryLabel
        empty.textAlignment = .center
        empty.numberOfLines = 0
        for view in [empty, loading] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            self.view.addSubview(view)
            NSLayoutConstraint.activate([
                view.centerXAnchor.constraint(equalTo: self.view.centerXAnchor),
                view.centerYAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.centerYAnchor),
                view.widthAnchor.constraint(lessThanOrEqualTo: self.view.readableContentGuide.widthAnchor),
            ])
        }
        follow()
    }

    private func switchKind() {
        kind = SharedKind.allCases[kinds.selectedSegmentIndex]
        collectionView.setCollectionViewLayout(layout(), animated: false)
        follow()
    }

    private func follow() {
        let model = model
        search.searchBar.placeholder = String(localized: "Search \(kind.title)")
        observation = model.changes.observe { [weak self] in self?.update() }
        update()
        // the kind switched to keeps the typed words.
        let text = search.searchBar.text ?? ""
        if model.query != text.trimmingCharacters(in: .whitespacesAndNewlines) {
            updateSearchResults(for: search)
        } else if model.items.isEmpty {
            Task { await model.loadMore() }
        }
    }

    func updateSearchResults(for searchController: UISearchController) {
        let model = model
        let text = searchController.searchBar.text ?? ""
        // a newer search makes this one's stale in the model.
        Task { await model.search(text) }
    }

    /// Photos in a grid of squares, four across on a phone and more on a wider screen; the
    /// others as an inset list.
    private func layout() -> UICollectionViewLayout {
        guard kind == .media else {
            return UICollectionViewCompositionalLayout.list(using: UICollectionLayoutListConfiguration(appearance: .insetGrouped))
        }
        return UICollectionViewCompositionalLayout { _, environment in
            let width = environment.container.effectiveContentSize.width
            let across = max(3, Int(width / 110))
            let side = NSCollectionLayoutDimension.fractionalWidth(1 / CGFloat(across))
            let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(widthDimension: side, heightDimension: .fractionalHeight(1)))
            item.contentInsets = NSDirectionalEdgeInsets(top: 1, leading: 1, bottom: 1, trailing: 1)
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: side),
                                                           repeatingSubitem: item, count: across)
            return NSCollectionLayoutSection(group: group)
        }
    }

    private func update() {
        let model = model
        items = Dictionary(model.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(model.items.map(\.id))
        dataSource.apply(snapshot, animatingDifferences: false)
        if model.isLoading && model.items.isEmpty { loading.startAnimating() } else { loading.stopAnimating() }
        empty.isHidden = !model.items.isEmpty || model.isLoading
        let none = switch kind {
        case .media: String(localized: "No photos or videos yet")
        case .files: String(localized: "No files yet")
        case .links: String(localized: "No links yet")
        }
        let found = model.query.isEmpty ? none : String(localized: "No Results for “\(model.query)”")
        empty.text = model.failure?.localizedDescription ?? found
        // a long stretch that shared nothing of this kind: read on until the screen fills or the start.
        if !model.isLoading, !model.isComplete, model.failure == nil, model.items.count < 24 {
            Task { await model.loadMore() }
        }
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        if indexPath.item >= model.items.count - 12 { Task { await model.loadMore() } }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath), let item = items[id] else { return }
        if case .link(let url, _) = item.content {
            UIApplication.shared.open(url)
            return
        }
        let model = model
        Task {
            do {
                previewed = try await model.file(of: item)
                let preview = QLPreviewController()
                preview.dataSource = self
                present(preview, animated: true)
            } catch {
                report(error, of: "shared file")
            }
        }
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { previewed == nil ? 0 : 1 }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
        (previewed ?? URL(fileURLWithPath: "/")) as NSURL
    }
}

private extension SharedItem.Content {
    var isMedia: Bool {
        switch self {
        case .photo, .video: true
        case .file, .link: false
        }
    }
}

/// A photo's or a video's square in the grid; a video shows its length.
private final class SharedTile: UICollectionViewCell {
    private let picture = RemoteImageView()
    private let length = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .secondarySystemFill
        picture.contentMode = .scaleAspectFill
        picture.clipsToBounds = true
        picture.frame = contentView.bounds
        picture.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(picture)
        length.font = .preferredFont(forTextStyle: .caption2).bold
        length.textColor = .white
        length.shadowColor = UIColor(white: 0, alpha: 0.5)
        length.shadowOffset = CGSize(width: 0, height: 1)
        length.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(length)
        NSLayoutConstraint.activate([
            length.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -5),
            length.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
        ])
        isAccessibilityElement = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(_ item: SharedItem, images: ImagePipeline?) {
        let pixels = Int(bounds.width * traitCollection.displayScale)
        picture.show(item.picture?.ref, pixels: max(pixels, 200), images: images)
        if case .video(_, let duration) = item.content {
            length.text = duration.map { Duration.seconds($0).formatted(.time(pattern: .minuteSecond)) } ?? String(localized: "Video")
            accessibilityLabel = String(localized: "Video from \(item.senderName)")
        } else {
            length.text = nil
            accessibilityLabel = String(localized: "Photo from \(item.senderName)")
        }
        accessibilityValue = item.date.formatted(date: .abbreviated, time: .shortened)
    }
}
