import AppKit
import LuxCore

/// What a search found, in the sidebar, as Messages shows it: the kinds' Liquid Glass buttons on
/// top (each opens its own list), then "Conversations", a few "Photos" (a grid), "Links", "Files"
/// and "Threads" (each with "Show All" when more were found), then "Messages". Before any words
/// are typed, what chats shared lately.
final class SearchResultsController: NSViewController, NSTableViewDelegate, NSMenuDelegate {
    enum Section: Int { case chats, photos, links, files, threads, messages }

    /// Opens a result: its chat (at its message), its thread, or its link.
    var onOpen: ((SearchTarget) -> Void)?
    /// Opens a kind's own list.
    var onShowAll: ((SearchKind) -> Void)?
    /// Esc while a result has the keyboard: search ends.
    var onCancel: (() -> Void)?

    private let images: ImagePipeline?
    private let table = NSTableView()
    private var dataSource: NSTableViewDiffableDataSource<Section, String>!
    private var rows: [String: ChatRow] = [:]
    private var targets: [String: SearchTarget] = [:]
    private var links: [String: FoundLink] = [:]
    private var files: [String: FoundFile] = [:]
    private var threads: [String: FoundThread] = [:]
    private var photos: [FoundPhoto] = []
    /// The kinds that have more than their section shows.
    private var more: Set<SearchKind> = []
    /// The one item of the photos section: their grid.
    private static let photoGrid = "photo-grid"
    private let kinds = SearchKindButtons()
    private let looking = LookingNote()
    /// While the index is still reading chats, or photos wait to be read: one small line.
    private let status = NSTextField(labelWithString: "")
    /// What the search found, all of it: the sections show a few of each kind.
    private var hits = SearchHits()
    private let scroll = NSScrollView()
    private let top = NSStackView()
    private var progress: SearchIndexer.Progress?
    /// The grid's own width, as its cell has it: the table's less the row's insets.
    private var gridWidth: CGFloat?
    private var laidOutWidth: CGFloat = 0

    init(images: ImagePipeline?) {
        self.images = images
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Esc reaches the view controller through the responder chain from the results' table.
    override func cancelOperation(_ sender: Any?) { onCancel?() }

    override func loadView() {
        table.addTableColumn(NSTableColumn(identifier: .init("found")))
        table.headerView = nil
        table.style = .sourceList
        table.intercellSpacing = .zero
        table.delegate = self
        table.setAccessibilityIdentifier("search-results")
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize - 1)
        status.textColor = .tertiaryLabelColor
        status.alignment = .center
        status.lineBreakMode = .byWordWrapping
        status.maximumNumberOfLines = 3
        status.cell?.wraps = true
        status.isHidden = true
        looking.isShown = false
        kinds.onOpen = { [weak self] kind in self?.onShowAll?(kind) }
        top.orientation = .vertical
        top.alignment = .centerX
        top.spacing = 8
        top.setViews([kinds, looking, status], in: .top)
        let container = NSView()
        for view in [top, scroll] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            top.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            top.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            top.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            kinds.widthAnchor.constraint(equalTo: top.widthAnchor),
            looking.widthAnchor.constraint(equalTo: top.widthAnchor),
            status.widthAnchor.constraint(equalTo: top.widthAnchor, constant: -24),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container

        let images = images
        dataSource = NSTableViewDiffableDataSource(tableView: table) { [weak self] table, _, _, id in
            guard let self else { return NSView() }
            if id == Self.photoGrid {
                let grid = table.makeView(withIdentifier: PhotoGridView.reuse, owner: nil) as? PhotoGridView ?? PhotoGridView()
                grid.show(photos, images: images)
                grid.onOpen = { [weak self] photo in self?.onOpen?(photo.target) }
                grid.onWidth = { [weak self] width in self?.gridGot(width) }
                return grid
            }
            if let link = links[id] {
                let cell = table.makeView(withIdentifier: SearchShareCell.reuse, owner: nil) as? SearchShareCell ?? SearchShareCell()
                cell.show(link)
                return cell
            }
            if let file = files[id] {
                let cell = table.makeView(withIdentifier: SearchShareCell.reuse, owner: nil) as? SearchShareCell ?? SearchShareCell()
                cell.show(file)
                return cell
            }
            if let thread = threads[id] {
                let cell = table.makeView(withIdentifier: SearchShareCell.reuse, owner: nil) as? SearchShareCell ?? SearchShareCell()
                cell.show(thread)
                return cell
            }
            let cell = table.makeView(withIdentifier: ChatCellView.reuse, owner: nil) as? ChatCellView ?? ChatCellView()
            if let row = rows[id] { cell.show(row, images: images) }
            return cell
        }
        // a chosen result stays in the accent colour, as in the chat list (ChatRowView).
        dataSource.rowViewProvider = { table, _, _ in
            table.makeView(withIdentifier: ChatRowView.reuse, owner: nil) as? ChatRowView
                ?? { let view = ChatRowView(); view.identifier = ChatRowView.reuse; return view }()
        }
        table.selectionHighlightStyle = .regular
        dataSource.sectionHeaderViewProvider = { [weak self] table, _, section in
            let header = table.makeView(withIdentifier: SearchSectionHeader.reuse, owner: nil) as? SearchSectionHeader
                ?? SearchSectionHeader()
            self?.configure(header, section)
            return header
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // the index may report before the results first show.
        showProgress(progress)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // a wider or narrower sidebar fits more or fewer photos in a row of the grid.
        guard table.bounds.width != laidOutWidth else { return }
        laidOutWidth = table.bounds.width
        render()
    }

    func show(_ hits: SearchHits) {
        let wasLooking = self.hits.isLookPending
        self.hits = hits
        render()
        showProgress(progress)
        guard wasLooking != hits.isLookPending else { return }
        // the note fades in, or out with the results moving up into its place.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.allowsImplicitAnimation = true
            looking.isShown = hits.isLookPending
            view.layoutSubtreeIfNeeded()
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

    private func render() {
        guard isViewLoaded else { return }
        rows = [:]; targets = [:]; links = [:]; files = [:]; threads = [:]
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
        // two rows of the grid.
        let width = gridWidth ?? table.bounds.width
        photos = Array(preview(hits.photos, .photos, PhotoGridView.columns(width) * 2))
        add(.photos, photos.isEmpty ? [] : [Self.photoGrid])
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
            targets[id] = found.target
            return id
        })
        dataSource.apply(snapshot, animatingDifferences: false)
        // the grid is one item, the same for new photos: it draws them, at their height.
        if let row = dataSource.row(forItemIdentifier: Self.photoGrid) {
            (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? PhotoGridView)?.show(photos, images: images)
            table.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
        }
        // the section headers' "Show All" follow what is found.
        for row in 0..<table.numberOfRows {
            guard let header = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? SearchSectionHeader,
                  let section = dataSource.sectionIdentifier(forRow: row) else { continue }
            configure(header, section)
        }
    }

    private func configure(_ header: SearchSectionHeader, _ section: Section) {
        let kind = Self.kind(of: section)
        header.show(Self.title(of: section), showAll: kind.flatMap { kind in
            more.contains(kind) ? { [weak self] in self?.onShowAll?(kind) } : nil
        })
    }

    /// The index's note while it is not complete, and why photos may be missing.
    func showProgress(_ progress: SearchIndexer.Progress?) {
        self.progress = progress
        guard isViewLoaded else { return }
        let note = hits.note(index: progress)
        status.stringValue = note ?? ""
        status.isHidden = note == nil
    }

    /// The grid is as tall as its rows of photos at the width it got; told after the layout pass
    /// that gave it, not in it.
    private func gridGot(_ width: CGFloat) {
        guard width != gridWidth else { return }
        gridWidth = width
        Task { @MainActor [weak self] in self?.render() }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch dataSource.itemIdentifier(forRow: row) {
        case nil: 28
        case Self.photoGrid?: PhotoGridView.height(for: photos.count, width: gridWidth ?? tableView.bounds.width)
        case let id? where id.hasPrefix("l") || id.hasPrefix("f") || id.hasPrefix("t"): 52
        default: 64
        }
    }

    /// The photos' grid is no row to choose: its thumbnails are.
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        dataSource.itemIdentifier(forRow: row) != Self.photoGrid
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard table.selectedRow >= 0, let id = dataSource.itemIdentifier(forRow: table.selectedRow),
              let target = targets[id] else { return }
        onOpen?(target)
        // a link opens in the browser: the row is not left chosen.
        if case .link = target { table.deselectAll(nil) }
    }

    /// A link's menu: open it, its message, or a copy.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard table.clickedRow >= 0, let id = dataSource.itemIdentifier(forRow: table.clickedRow), let link = links[id] else { return }
        for item in SearchViews.menu(for: link, open: { [weak self] target in self?.onOpen?(target) }).items {
            item.menu?.removeItem(item)
            menu.addItem(item)
        }
    }
}
