import LuxCore
import UIKit

/// One kind of what chats shared, all of it, on its own page ("Show All", or a kind's button over
/// the results): photos as a grid, links, files and threads as rows, the newest first. Its own
/// search field starts with the words searched, and finds in this kind only; the next page loads
/// as the list nears its end.
final class SearchListViewController: UIViewController, UICollectionViewDelegate, UISearchResultsUpdating {
    private let model: SearchListModel
    private let images: ImagePipeline?
    private let open: (SearchTarget) -> Void
    private var hits = SearchHits()
    private let looking = LookingNote()
    private let empty = UILabel()
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!

    init(model: SearchListModel, images: ImagePipeline?, open: @escaping (SearchTarget) -> Void) {
        self.model = model
        self.images = images
        self.open = open
        super.init(nibName: nil, bundle: nil)
        title = model.kind.title
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let kind = model.kind
        let list = UICollectionLayoutListConfiguration(appearance: .plain)
        let layout = UICollectionViewCompositionalLayout { _, environment in
            kind == .photos
                ? SearchViews.photoGrid(width: environment.container.effectiveContentSize.width, header: false)
                : NSCollectionLayoutSection.list(using: list, layoutEnvironment: environment)
        }
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.keyboardDismissMode = .onDrag
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "search-list"
        collectionView.topEdgeEffect.style = .soft
        view.addSubview(collectionView)

        let search = UISearchController(searchResultsController: nil)
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = String(localized: "Search \(kind.title)")
        search.searchBar.text = model.query
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        navigationItem.preferredSearchBarPlacement = .stacked

        looking.isShown = false
        looking.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(looking)
        empty.font = .preferredFont(forTextStyle: .body)
        empty.textColor = .secondaryLabel
        empty.textAlignment = .center
        empty.numberOfLines = 0
        empty.isHidden = true
        empty.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(empty)
        NSLayoutConstraint.activate([
            looking.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            looking.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            looking.widthAnchor.constraint(lessThanOrEqualTo: view.layoutMarginsGuide.widthAnchor),
            empty.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            empty.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            empty.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
        ])

        let images = images
        let photoCell = UICollectionView.CellRegistration<SearchPhotoCell, String> { [weak self] cell, _, id in
            guard let photo = self?.hits.photos.first(where: { $0.id == id }) else { return }
            cell.show(photo, images: images)
        }
        let rowCell = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, indexPath, _ in
            guard let self else { return }
            switch kind {
            case .links: cell.contentConfiguration = SearchViews.link(hits.links[indexPath.item])
            case .files: cell.contentConfiguration = SearchViews.file(hits.files[indexPath.item])
            case .threads: cell.contentConfiguration = SearchViews.thread(hits.threads[indexPath.item])
            case .photos: break
            }
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, id in
            kind == .photos
                ? collectionView.dequeueConfiguredReusableCell(using: photoCell, for: indexPath, item: id)
                : collectionView.dequeueConfiguredReusableCell(using: rowCell, for: indexPath, item: id)
        }
        model.onUpdate = { [weak self] hits in self?.show(hits) }
        show(model.hits)
    }

    private func show(_ hits: SearchHits) {
        let wasLooking = self.hits.isLookPending
        self.hits = hits
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(ids)
        dataSource.applySnapshotUsingReloadData(snapshot)
        empty.text = model.query.isEmpty
            ? String(localized: "No \(model.kind.title.lowercased()) yet")
            : String(localized: "No results for “\(model.query)”")
        empty.isHidden = !ids.isEmpty || hits.isLookPending || !model.hasLoaded
        guard wasLooking != hits.isLookPending else { return }
        // the note fades in, or out with the list moving up into its place.
        UIView.animate(withDuration: 0.35, delay: 0, options: [.beginFromCurrentState, .curveEaseInOut]) { [self] in
            looking.isShown = hits.isLookPending
            collectionView.contentInset.top = hits.isLookPending ? looking.bounds.height + 16 : 0
        }
    }

    private var ids: [String] {
        switch model.kind {
        case .photos: hits.photos.map(\.id)
        case .links: hits.links.map(\.id)
        case .files: hits.files.map(\.id)
        case .threads: hits.threads.map(\.id)
        }
    }

    func updateSearchResults(for searchController: UISearchController) {
        model.search(searchController.searchBar.text ?? "")
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        // the next page, a screen ahead of the end.
        if indexPath.item >= ids.count - 20 { model.loadMore() }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        let item = indexPath.item
        let target: SearchTarget? = switch model.kind {
        case .photos: hits.photos[safe: item]?.target
        case .links: hits.links[safe: item]?.target
        case .files: hits.files[safe: item]?.target
        case .threads: hits.threads[safe: item]?.target
        }
        if let target { open(target) }
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard model.kind == .links, let item = indexPaths.first?.item, let link = hits.links[safe: item] else { return nil }
        return SearchViews.menu(for: link) { [weak self] target in self?.open(target) }
    }
}
