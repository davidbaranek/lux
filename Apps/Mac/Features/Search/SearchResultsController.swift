import AppKit
import LuxCore

/// What a search found, under "Conversations", "Photos" (a grid of thumbnails) and "Messages", in
/// the chat list's own row view.
final class SearchResultsController: NSViewController, NSTableViewDelegate {
    enum Section: Int { case chats, photos, messages }

    /// A chat to open (a found message opens its chat).
    /// Opens a chat; at the message found, for a found message.
    var onOpen: ((ChatRow, _ focusEvent: String?) -> Void)?

    private let images: ImagePipeline?
    private let table = NSTableView()
    private var dataSource: NSTableViewDiffableDataSource<Section, String>!
    private var rows: [String: ChatRow] = [:]
    private var chats: [String: ChatRow] = [:]
    private var photos: [FoundPhoto] = []
    /// The width the grid's height was measured at.
    private var laidOutWidth: CGFloat = 0
    /// The one item of the photos section: their grid.
    private static let photoGrid = "photo-grid"
    /// While the index is still reading chats, one small line under the results.
    private let status = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()
    private var progress: SearchIndexer.Progress?
    private lazy var scrollAboveStatus = scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -6)

    init(images: ImagePipeline?) {
        self.images = images
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        table.addTableColumn(NSTableColumn(identifier: .init("found")))
        table.headerView = nil
        table.style = .sourceList
        table.intercellSpacing = .zero
        table.delegate = self
        table.setAccessibilityIdentifier("search-results")
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize - 1)
        status.textColor = .tertiaryLabelColor
        status.alignment = .center
        status.lineBreakMode = .byTruncatingTail
        status.isHidden = true
        let container = NSView()
        for view in [scroll, status] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            status.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            status.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            status.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor).withPriority(.defaultLow),
        ])
        view = container

        let images = images
        dataSource = NSTableViewDiffableDataSource(tableView: table) { [weak self] table, _, _, id in
            if id == Self.photoGrid {
                let grid = table.makeView(withIdentifier: PhotoGridView.reuse, owner: nil) as? PhotoGridView ?? PhotoGridView()
                grid.show(self?.photos ?? [], images: images)
                grid.onOpen = { [weak self] photo in self?.onOpen?(photo.chat, photo.id) }
                return grid
            }
            let cell = table.makeView(withIdentifier: ChatCellView.reuse, owner: nil) as? ChatCellView ?? ChatCellView()
            if let row = self?.rows[id] { cell.show(row, images: images) }
            return cell
        }
        // a chosen result stays in the accent colour, as in the chat list (ChatRowView).
        dataSource.rowViewProvider = { table, _, _ in
            table.makeView(withIdentifier: ChatRowView.reuse, owner: nil) as? ChatRowView
                ?? { let view = ChatRowView(); view.identifier = ChatRowView.reuse; return view }()
        }
        table.selectionHighlightStyle = .regular
        dataSource.sectionHeaderViewProvider = { table, _, section in
            let header = table.makeView(withIdentifier: SectionHeader.reuse, owner: nil) as? SectionHeader ?? SectionHeader()
            header.title = switch section {
            case .chats: String(localized: "Conversations")
            case .photos: String(localized: "Photos")
            case .messages: String(localized: "Messages")
            }
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
        // a wider or narrower window fits more or fewer photos in a row of the grid.
        guard table.bounds.width != laidOutWidth else { return }
        laidOutWidth = table.bounds.width
        if let row = dataSource.row(forItemIdentifier: Self.photoGrid) {
            table.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
        }
    }

    func show(_ hits: SearchHits) {
        let found = hits.messages.map(\.row)
        photos = hits.photos
        rows = Dictionary((hits.chats + found).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        chats = Dictionary(hits.messages.map { ($0.id, $0.chat) }, uniquingKeysWith: { first, _ in first })
        var snapshot = NSDiffableDataSourceSnapshot<Section, String>()
        if !hits.chats.isEmpty {
            snapshot.appendSections([.chats])
            snapshot.appendItems(hits.chats.map(\.id), toSection: .chats)
        }
        if !photos.isEmpty {
            snapshot.appendSections([.photos])
            snapshot.appendItems([Self.photoGrid], toSection: .photos)
        }
        if !found.isEmpty {
            snapshot.appendSections([.messages])
            snapshot.appendItems(found.map(\.id).filter { !snapshot.itemIdentifiers.contains($0) }, toSection: .messages)
        }
        dataSource.apply(snapshot, animatingDifferences: false)
        // the grid is one item, the same for new photos: it draws them, at their height.
        if let row = dataSource.row(forItemIdentifier: Self.photoGrid) {
            (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? PhotoGridView)?.show(photos, images: images)
            table.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
        }
    }

    /// The index's note while it is not complete; nothing once it is. The results end above it.
    func showProgress(_ progress: SearchIndexer.Progress?) {
        self.progress = progress
        guard isViewLoaded else { return }
        let note = progress?.note
        status.stringValue = note ?? ""
        status.isHidden = note == nil
        // the results end above the line while it shows.
        scrollAboveStatus.isActive = note != nil
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch dataSource.itemIdentifier(forRow: row) {
        case nil: 28
        case Self.photoGrid?: PhotoGridView.height(for: photos.count, width: tableView.bounds.width)
        default: 64
        }
    }

    /// The photos' grid is no row to choose: its thumbnails are.
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        dataSource.itemIdentifier(forRow: row) != Self.photoGrid
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard table.selectedRow >= 0, let id = dataSource.itemIdentifier(forRow: table.selectedRow) else { return }
        // a found message's id is its event's: its chat opens there.
        if let chat = chats[id] {
            onOpen?(chat, id)
        } else if let chat = rows[id] {
            onOpen?(chat, nil)
        }
    }
}
