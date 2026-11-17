import LuxCore
import UIKit

/// What a search found, as Messages shows it: the kinds' Liquid Glass buttons on top (each opens
/// its own list), then "Conversations", a few "Photos", "Links", "Files" and "Threads" (each with
/// "Show All" when more were found), then "Messages". Before any words are typed, what chats
/// shared lately, a few of each kind.
final class SearchResultsViewController: UIViewController, UICollectionViewDelegate {
    enum Section: Int { case chats, photos, links, files, threads, messages }

    private let images: ImagePipeline?
    /// Opens a result: its chat (at its message), its thread, or its link.
    private let open: (SearchTarget) -> Void
    /// Opens a kind's own list, with the words typed.
    private let showAll: (SearchKind) -> Void
    private var hits = SearchHits()
    private var progress: SearchIndexer.Progress?
    /// The results by their item id: a section's letter and the result's id.
    private var rows: [String: ChatRow] = [:]
    private var highlights: [String: [NSRange]] = [:]
    private var targets: [String: SearchTarget] = [:]
    private var photos: [String: FoundPhoto] = [:]
    private var links: [String: FoundLink] = [:]
    private var files: [String: FoundFile] = [:]
    private var threads: [String: FoundThread] = [:]
    /// The kinds that have more than their section shows.
    private var more: Set<SearchKind> = []
    private let kinds = SearchKindButtons()
    /// While the index is still reading chats, or photos wait to be read: one small line.
    private let status = UILabel()
    private let looking = LookingNote()
    private let top = UIStackView()
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, String>!

    init(images: ImagePipeline?, open: @escaping (SearchTarget) -> Void, showAll: @escaping (SearchKind) -> Void) {
        self.images = images
        self.open = open
        self.showAll = showAll
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        var list = UICollectionLayoutListConfiguration(appearance: .plain)
        list.headerMode = .supplementary
        // the headers' own spacing is enough: no more over each section.
        list.headerTopPadding = 0
        let layout = UICollectionViewCompositionalLayout { [weak self] index, environment in
            guard self?.dataSource.sectionIdentifier(for: index) == .photos else {
                return NSCollectionLayoutSection.list(using: list, layoutEnvironment: environment)
            }
            return SearchViews.photoGrid(width: environment.container.effectiveContentSize.width, header: true)
        }
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.keyboardDismissMode = .onDrag
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "search-results"
        view.addSubview(collectionView)
        // what scrolls under the bar blurs out gradually, not at a hard edge (the system's default).
        collectionView.topEdgeEffect.style = .soft

        kinds.onOpen = { [weak self] kind in self?.showAll(kind) }
        status.font = .preferredFont(forTextStyle: .caption2)
        status.adjustsFontForContentSizeCategory = true
        status.textColor = .tertiaryLabel
        status.textAlignment = .center
        status.numberOfLines = 0
        status.isHidden = true
        looking.isShown = false
        top.axis = .vertical
        top.spacing = 8
        top.alignment = .center
        for view in [kinds, status, looking] as [UIView] { top.addArrangedSubview(view) }
        top.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(top)
        NSLayoutConstraint.activate([
            top.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            top.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            top.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            kinds.widthAnchor.constraint(equalTo: top.widthAnchor),
            status.widthAnchor.constraint(lessThanOrEqualTo: view.layoutMarginsGuide.widthAnchor),
            looking.widthAnchor.constraint(lessThanOrEqualTo: view.layoutMarginsGuide.widthAnchor),
        ])

        let images = images
        let chatCell = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, _, id in
            guard let row = self?.rows[id] else { return }
            cell.contentConfiguration = ChatRowConfiguration(row: row, images: images, highlights: self?.highlights[id] ?? [])
        }
        let shareCell = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, _, id in
            guard let self else { return }
            if let link = links[id] {
                cell.contentConfiguration = SearchViews.link(link)
            } else if let file = files[id] {
                cell.contentConfiguration = SearchViews.file(file)
            } else if let thread = threads[id] {
                cell.contentConfiguration = SearchViews.thread(thread)
            }
        }
        let photoCell = UICollectionView.CellRegistration<SearchPhotoCell, String> { [weak self] cell, _, id in
            guard let found = self?.photos[id] else { return }
            cell.show(found, images: images)
        }
        let header = UICollectionView.SupplementaryRegistration<SearchSectionHeader>(elementKind: UICollectionView.elementKindSectionHeader) {
            [weak self] header, _, indexPath in
            guard let self, let section = dataSource.sectionIdentifier(for: indexPath.section) else { return }
            let kind = Self.kind(of: section)
            header.show(Self.title(of: section), showAll: kind.flatMap { kind in
                more.contains(kind) ? { [weak self] in self?.showAll(kind) } : nil
            })
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, id in
            switch id.first {
            case "p": collectionView.dequeueConfiguredReusableCell(using: photoCell, for: indexPath, item: id)
            case "l", "f", "t": collectionView.dequeueConfiguredReusableCell(using: shareCell, for: indexPath, item: id)
            default: collectionView.dequeueConfiguredReusableCell(using: chatCell, for: indexPath, item: id)
            }
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
        showProgress(progress)
        render()
    }

    /// Shown again (back from a kind's list): the results follow the field's words.
    var onAppear: (() -> Void)?
    private var appeared = false

    /// Search opens: the kinds' buttons slide in under the field, quickly.
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // the results need no bar; a kind's list over them has one, with its back button.
        navigationController?.setNavigationBarHidden(true, animated: animated)
        if appeared { onAppear?() }
        appeared = true
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        kinds.alpha = 0
        kinds.transform = CGAffineTransform(translationX: 0, y: -10).scaledBy(x: 0.96, y: 0.96)
        UIView.animate(withDuration: 0.32, delay: 0.04, usingSpringWithDamping: 0.85, initialSpringVelocity: 0,
                       options: [.allowUserInteraction, .beginFromCurrentState]) { [self] in
            kinds.alpha = 1
            kinds.transform = .identity
        }
    }

    func show(_ hits: SearchHits) {
        let wasLooking = self.hits.isLookPending
        self.hits = hits
        render()
        showProgress(progress)
        guard isViewLoaded, wasLooking != hits.isLookPending else { return }
        // the note fades in, or out with the results moving up into its place.
        UIView.animate(withDuration: 0.35, delay: 0, options: [.beginFromCurrentState, .curveEaseInOut]) { [self] in
            looking.isShown = hits.isLookPending
            top.layoutIfNeeded()
            updateInset()
        }
    }

    private static func title(of section: Section) -> String {
        switch section {
        case .chats: String(localized: "Conversations")
        case .photos: SearchKind.photos.title
        case .links: SearchKind.links.title
        case .files: SearchKind.files.title
        case .threads: SearchKind.threads.title
        case .messages: String(localized: "Messages")
        }
    }

    private static func kind(of section: Section) -> SearchKind? {
        switch section {
        case .photos: .photos
        case .links: .links
        case .files: .files
        case .threads: .threads
        case .chats, .messages: nil
        }
    }

    /// How many photos the results show: two rows of the grid.
    private var photoPreview: Int { SearchViews.photoColumns(width: view.bounds.width) * 2 }

    private func render() {
        guard isViewLoaded else { return }
        rows = [:]; highlights = [:]; targets = [:]; photos = [:]; links = [:]; files = [:]; threads = [:]
        more = []
        var snapshot = NSDiffableDataSourceSnapshot<Section, String>()
        func add(_ section: Section, _ ids: [String]) {
            guard !ids.isEmpty else { return }
            snapshot.appendSections([section])
            snapshot.appendItems(ids, toSection: section)
        }
        func preview<Found>(_ found: [Found], _ kind: SearchKind, _ count: Int) -> ArraySlice<Found> {
            if found.count > count { more.insert(kind) }
            return found.prefix(count)
        }
        add(.chats, hits.chats.map { row in
            let id = "c\(row.id)"
            rows[id] = row
            targets[id] = .chat(row, focus: nil)
            return id
        })
        add(.photos, preview(hits.photos, .photos, photoPreview).map { photo in
            let id = "p\(photo.id)"
            photos[id] = photo
            targets[id] = photo.target
            return id
        })
        add(.links, preview(hits.links, .links, SearchKind.links.preview).map { link in
            let id = "l\(link.id)"
            links[id] = link
            targets[id] = link.target
            return id
        })
        add(.files, preview(hits.files, .files, SearchKind.files.preview).map { file in
            let id = "f\(file.id)"
            files[id] = file
            targets[id] = file.target
            return id
        })
        add(.threads, preview(hits.threads, .threads, SearchKind.threads.preview).map { thread in
            let id = "t\(thread.id)"
            threads[id] = thread
            targets[id] = thread.target
            return id
        })
        add(.messages, hits.messages.map { found in
            let id = "m\(found.id)"
            rows[id] = found.row
            highlights[id] = found.previewMatches
            targets[id] = found.target
            return id
        })
        dataSource.applySnapshotUsingReloadData(snapshot)
    }

    /// The index's note while it is not complete, and why photos may be missing.
    func showProgress(_ progress: SearchIndexer.Progress?) {
        // kept for when the results first show: the index may report before search opens.
        self.progress = progress
        guard isViewLoaded else { return }
        let note = hits.note(index: progress)
        status.text = note
        status.isHidden = note == nil
        updateInset()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateInset()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        // a wider screen shows more photos in its two rows.
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in self?.render() }
    }

    /// The results start under the buttons and the notes.
    private func updateInset() {
        let height = top.systemLayoutSizeFitting(CGSize(width: view.bounds.width, height: 0),
                                                 withHorizontalFittingPriority: .required,
                                                 verticalFittingPriority: .fittingSizeLevel).height + 8
        if collectionView.contentInset.top != height { collectionView.contentInset.top = height }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath), let target = targets[id] else { return }
        open(target)
    }

    /// A link: its page on a tap; its message, or a copy, from the menu.
    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first, let id = dataSource.itemIdentifier(for: indexPath), let link = links[id] else {
            return nil
        }
        return SearchViews.menu(for: link) { [weak self] target in self?.open(target) }
    }
}
