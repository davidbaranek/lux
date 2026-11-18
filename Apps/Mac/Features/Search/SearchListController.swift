import AppKit
import LuxCore

/// One kind of what chats shared, all of it, in the sidebar in place of the results ("Show All",
/// or a kind's button): a back button and the kind's name over photos as a grid, or links, files
/// and threads as rows, the newest first. The sidebar's search field searches this kind while it
/// shows; the next page loads as the list nears its end.
final class SearchListController: NSViewController, NSTableViewDelegate, NSCollectionViewDelegate, NSMenuDelegate {
    /// Back to the results.
    var onBack: (() -> Void)?
    var onOpen: ((SearchTarget) -> Void)?
    /// Esc while an item has the keyboard: search ends.
    var onCancel: (() -> Void)?

    let model: SearchListModel
    private let images: ImagePipeline?
    private var hits = SearchHits()
    private let table = NSTableView()
    private var rows: NSTableViewDiffableDataSource<Int, String>!
    private let grid = NSCollectionView()
    private var photos: NSCollectionViewDiffableDataSource<Int, String>!
    /// The rows' and the photos' hits by id, as the data sources name them.
    private var links: [String: FoundLink] = [:]
    private var files: [String: FoundFile] = [:]
    private var threads: [String: FoundThread] = [:]
    private var found: [String: FoundPhoto] = [:]
    private let scroll = NSScrollView()
    private let looking = LookingNote()
    private let empty = NSTextField(labelWithString: "")

    init(model: SearchListModel, images: ImagePipeline?) {
        self.model = model
        self.images = images
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let back = NSButton(image: NSImage(systemSymbolName: "chevron.left", accessibilityDescription: String(localized: "Back"))!,
                            target: self, action: #selector(goBack))
        back.bezelStyle = .glass
        back.borderShape = .circle
        back.controlSize = .large
        back.toolTip = String(localized: "Back to Results")
        back.setAccessibilityIdentifier("search-list-back")
        let title = NSTextField(labelWithString: model.kind.title)
        title.font = .systemFont(ofSize: NSFont.systemFontSize + 2, weight: .semibold)
        let bar = NSStackView(views: [back, title])
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        if model.kind == .photos {
            // a collection view: only the squares on screen exist, and their pictures load as they show.
            grid.collectionViewLayout = Self.gridLayout()
            grid.isSelectable = true
            grid.backgroundColors = [.clear]
            grid.delegate = self
            grid.register(FoundPhotoItem.self, forItemWithIdentifier: FoundPhotoItem.identifier)
            grid.setAccessibilityIdentifier("search-list")
            let images = images
            photos = NSCollectionViewDiffableDataSource(collectionView: grid) { [weak self] grid, indexPath, id in
                guard let self, let photo = found[id] else { return nil }
                let tile = grid.makeItem(withIdentifier: FoundPhotoItem.identifier, for: indexPath)
                (tile as? FoundPhotoItem)?.show(photo, images: images)
                return tile
            }
            scroll.documentView = grid
        } else {
            table.addTableColumn(NSTableColumn(identifier: .init("item")))
            table.headerView = nil
            table.style = .sourceList
            table.intercellSpacing = .zero
            table.rowHeight = 52
            table.delegate = self
            rows = NSTableViewDiffableDataSource(tableView: table) { [weak self] table, _, _, id in
                let cell = table.makeView(withIdentifier: SearchShareCell.reuse, owner: nil) as? SearchShareCell ?? SearchShareCell()
                guard let self else { return cell }
                if let link = links[id] { cell.show(link) } else if let file = files[id] { cell.show(file) } else if let thread = threads[id] { cell.show(thread) }
                return cell
            }
            let menu = NSMenu()
            menu.delegate = self
            table.menu = menu
            scroll.documentView = table
            table.setAccessibilityIdentifier("search-list")
        }

        looking.isShown = false
        empty.textColor = .secondaryLabelColor
        empty.alignment = .center
        empty.isHidden = true
        // the bar, and the note under it while it shows (a hidden one takes no room).
        let top = NSStackView(views: [bar, looking])
        top.orientation = .vertical
        top.alignment = .leading
        top.spacing = 8
        let container = NSView()
        for view in [top, scroll, empty] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            top.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            top.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            top.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            looking.widthAnchor.constraint(equalTo: top.widthAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            empty.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -24),
        ])
        view = container
        model.onUpdate = { [weak self] hits in self?.show(hits) }
        show(model.hits)
    }

    /// The sidebar's field changed while this list shows.
    func search(_ text: String) {
        model.search(text)
    }

    private func show(_ hits: SearchHits) {
        let wasLooking = self.hits.isLookPending
        self.hits = hits
        // a page or a new query inserts and removes rows; those that stay are kept (no `reloadData`).
        // each hit is once in its list: the index keys them (and a page adds only what is new).
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        switch model.kind {
        case .photos:
            found = Dictionary(uniqueKeysWithValues: hits.photos.map { ($0.id, $0) })
            snapshot.appendItems(hits.photos.map(\.id))
            photos.apply(snapshot, animatingDifferences: false)
        case .links, .files, .threads:
            links = Dictionary(uniqueKeysWithValues: hits.links.map { ($0.id, $0) })
            files = Dictionary(uniqueKeysWithValues: hits.files.map { ($0.id, $0) })
            threads = Dictionary(uniqueKeysWithValues: hits.threads.map { ($0.id, $0) })
            let ids = switch model.kind {
            case .links: hits.links.map(\.id)
            case .files: hits.files.map(\.id)
            default: hits.threads.map(\.id)
            }
            snapshot.appendItems(ids)
            rows.apply(snapshot, animatingDifferences: false)
        }
        empty.stringValue = model.query.isEmpty
            ? String(localized: "No \(model.kind.title.lowercased()) yet")
            : String(localized: "No results for “\(model.query)”")
        empty.isHidden = hits.count(of: model.kind) > 0 || hits.isLookPending || !model.hasLoaded
        guard wasLooking != hits.isLookPending else { return }
        // the note fades in, or out with the list moving up into its place.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.allowsImplicitAnimation = true
            looking.isShown = hits.isLookPending
            view.layoutSubtreeIfNeeded()
        }
    }

    /// Squares at least 76 points wide, as many as fit across, 4 points apart.
    private static func gridLayout() -> NSCollectionViewLayout {
        NSCollectionViewCompositionalLayout { _, environment in
            let spacing: CGFloat = 4
            let width = environment.container.effectiveContentSize.width - 16
            let across = PhotoGridView.columns(width)
            let side = NSCollectionLayoutDimension.fractionalWidth(1 / CGFloat(across))
            let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(widthDimension: side, heightDimension: .fractionalHeight(1)))
            item.contentInsets = NSDirectionalEdgeInsets(top: spacing / 2, leading: spacing / 2, bottom: spacing / 2, trailing: spacing / 2)
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: side),
                                                           subitem: item, count: across)
            let section = NSCollectionLayoutSection(group: group)
            section.contentInsets = NSDirectionalEdgeInsets(top: spacing / 2, leading: 8 - spacing / 2, bottom: spacing / 2, trailing: 8 - spacing / 2)
            return section
        }
    }

    // MARK: Photos

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        collectionView.deselectItems(at: indexPaths)
        guard let photo = indexPaths.first.flatMap(photos.itemIdentifier(for:)).flatMap({ found[$0] }) else { return }
        onOpen?(photo.target)
    }

    /// A square near the end of what was found shows: the next page.
    func collectionView(_ collectionView: NSCollectionView, willDisplay item: NSCollectionViewItem,
                        forRepresentedObjectAt indexPath: IndexPath) {
        if indexPath.item >= hits.photos.count - 40 { model.loadMore() }
    }

    @objc private func goBack() { onBack?() }

    /// Esc reaches the view controller through the responder chain from the list or the grid.
    override func cancelOperation(_ sender: Any?) { onCancel?() }

    // MARK: Rows

    /// A row near the end of what was found comes on screen: the next page.
    func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
        if row >= hits.count(of: model.kind) - 20 { model.loadMore() }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        tableView.makeView(withIdentifier: ChatRowView.reuse, owner: nil) as? ChatRowView
            ?? { let view = ChatRowView(); view.identifier = ChatRowView.reuse; return view }()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard table.selectedRow >= 0, let id = rows.itemIdentifier(forRow: table.selectedRow),
              let target = links[id]?.target ?? files[id]?.target ?? threads[id]?.target else { return }
        onOpen?(target)
        if case .link = target { table.deselectAll(nil) }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard model.kind == .links, table.clickedRow >= 0, let id = rows.itemIdentifier(forRow: table.clickedRow),
              let link = links[id] else { return }
        for item in SearchViews.menu(for: link, open: { [weak self] target in self?.onOpen?(target) }).items {
            item.menu?.removeItem(item)
            menu.addItem(item)
        }
    }
}

/// A photo that search found, as a square of the grid; a click opens its chat at it.
private final class FoundPhotoItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("found-photo")
    private let picture = RemoteImageView()

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        container.layer?.cornerRadius = 4
        container.layer?.masksToBounds = true
        picture.frame = container.bounds
        picture.autoresizingMask = [.width, .height]
        container.addSubview(picture)
        view = container
    }

    func show(_ photo: FoundPhoto, images: ImagePipeline?) {
        picture.show(photo.image, pixels: 240, images: images)
        view.toolTip = photo.chat.name
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.image)
        view.setAccessibilityLabel(String(localized: "Photo from \(photo.isOwn ? String(localized: "you") : photo.senderName) in \(photo.chat.name)"))
    }
}
