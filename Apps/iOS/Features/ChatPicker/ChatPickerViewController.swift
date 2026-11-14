import LuxCore
import UIKit

/// Picks a chat (to forward a message to): the inbox, newest first, filtered as you type.
final class ChatPickerViewController: UIViewController, UICollectionViewDelegate, UISearchResultsUpdating {
    private let session: Session
    private let model: ChatListModel
    private let pick: (ChatRow) -> Void
    private var rows: [ChatRow] = []
    private var filter = ""
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private var byId: [String: ChatRow] = [:]

    init(session: Session, title: String, pick: @escaping (ChatRow) -> Void) {
        self.session = session
        self.pick = pick
        model = ChatListModel(session: session)
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        let search = UISearchController(searchResultsController: nil)
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false

        collectionView = UICollectionView(frame: view.bounds,
                                          collectionViewLayout: UICollectionViewCompositionalLayout.list(using: .init(appearance: .plain)))
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.delegate = self
        view.addSubview(collectionView)
        // what scrolls under the bar blurs out gradually, not at a hard edge (the system's default).
        collectionView.topEdgeEffect.style = .soft
        let images = session.images
        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, _, id in
            guard let row = self?.byId[id] else { return }
            cell.contentConfiguration = ChatRowConfiguration(row: row, images: images)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: id)
        }
        model.onUpdate = { [weak self] sections, _ in
            self?.rows = sections.flatMap(\.rows)
            self?.update()
        }
        Task { await model.reload() }
    }

    func updateSearchResults(for searchController: UISearchController) {
        filter = searchController.searchBar.text?.trimmingCharacters(in: .whitespaces) ?? ""
        update()
    }

    private func update() {
        let shown = filter.isEmpty ? rows : rows.filter { $0.name.localizedStandardContains(filter) }
        byId = Dictionary(shown.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(shown.map(\.id))
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let id = dataSource.itemIdentifier(for: indexPath), let row = byId[id] else { return }
        pick(row)
        dismiss(animated: true)
    }
}
