import LuxCore
import UIKit

/// What a search found: "Conversations", then "Messages", in the chat list's own row.
final class SearchResultsViewController: UIViewController, UICollectionViewDelegate {
    enum Section: Int { case chats, messages }

    private let images: ImagePipeline?
    private let open: (ChatRow) -> Void
    private var rows: [String: ChatRow] = [:]
    private var chats: [String: ChatRow] = [:]
    private var highlights: [String: [NSRange]] = [:]
    /// While the index is still reading chats, one small line over the results: they are what it
    /// has so far. (The search field is at the bottom, so the line is at the top.)
    private let status = UILabel()
    private var progress: SearchIndexer.Progress?
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, String>!

    init(images: ImagePipeline?, open: @escaping (ChatRow) -> Void) {
        self.images = images
        self.open = open
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        var list = UICollectionLayoutListConfiguration(appearance: .plain)
        list.headerMode = .supplementary
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: list))
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
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) {
            [weak self] header, _, indexPath in
            var content = header.defaultContentConfiguration()
            content.text = self?.dataSource.sectionIdentifier(for: indexPath.section) == .chats
                ? String(localized: "Conversations") : String(localized: "Messages")
            header.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: id)
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
        var snapshot = NSDiffableDataSourceSnapshot<Section, String>()
        if !hits.chats.isEmpty {
            snapshot.appendSections([.chats])
            snapshot.appendItems(hits.chats.map(\.id), toSection: .chats)
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

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath), let chat = chats[id] ?? rows[id] else { return }
        open(chat)
    }
}
