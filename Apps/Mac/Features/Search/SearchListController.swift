import AppKit
import LuxCore

/// One kind of what chats shared, all of it, in the sidebar in place of the results ("Show All",
/// or a kind's button): a back button and the kind's name over photos as a grid, or links, files
/// and threads as rows, the newest first. The sidebar's search field searches this kind while it
/// shows; the next page loads as the list nears its end.
final class SearchListController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    /// Back to the results.
    var onBack: (() -> Void)?
    var onOpen: ((SearchTarget) -> Void)?

    let model: SearchListModel
    private let images: ImagePipeline?
    private var hits = SearchHits()
    private let table = NSTableView()
    private let grid = PhotoGridView()
    /// The grid's own scroll view: its document is the grid, as tall as its rows.
    private let gridDocument = FlippedView()
    private var gridHeight: NSLayoutConstraint?
    private let scroll = NSScrollView()
    private let looking = LookingNote()
    private let empty = NSTextField(labelWithString: "")
    private var scrolled: AnyObject?

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
            grid.translatesAutoresizingMaskIntoConstraints = false
            gridDocument.addSubview(grid)
            gridDocument.translatesAutoresizingMaskIntoConstraints = false
            scroll.documentView = gridDocument
            let height = grid.heightAnchor.constraint(equalToConstant: 0)
            gridHeight = height
            NSLayoutConstraint.activate([
                gridDocument.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
                gridDocument.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
                gridDocument.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
                grid.leadingAnchor.constraint(equalTo: gridDocument.leadingAnchor, constant: 8),
                grid.trailingAnchor.constraint(equalTo: gridDocument.trailingAnchor, constant: -8),
                grid.topAnchor.constraint(equalTo: gridDocument.topAnchor),
                grid.bottomAnchor.constraint(equalTo: gridDocument.bottomAnchor),
                height,
            ])
            grid.onOpen = { [weak self] photo in self?.onOpen?(photo.target) }
            grid.onWidth = { [weak self] _ in Task { @MainActor in self?.fitGrid() } }
        } else {
            table.addTableColumn(NSTableColumn(identifier: .init("item")))
            table.headerView = nil
            table.style = .sourceList
            table.intercellSpacing = .zero
            table.rowHeight = 52
            table.dataSource = self
            table.delegate = self
            let menu = NSMenu()
            menu.delegate = self
            table.menu = menu
            scroll.documentView = table
        }
        table.setAccessibilityIdentifier("search-list")
        // the next page, as the end comes near.
        scroll.contentView.postsBoundsChangedNotifications = true
        scrolled = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.loadMoreIfNear() }
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
        if model.kind == .photos {
            grid.show(hits.photos, images: images)
            fitGrid()
        } else {
            table.reloadData()
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

    private func fitGrid() {
        let width = grid.bounds.width > 0 ? grid.bounds.width : scroll.contentSize.width - 16
        gridHeight?.constant = PhotoGridView.height(for: hits.photos.count, width: width)
    }

    private func loadMoreIfNear() {
        guard let document = scroll.documentView else { return }
        let visible = scroll.contentView.bounds
        if document.bounds.height - visible.maxY < visible.height { model.loadMore() }
    }

    @objc private func goBack() { onBack?() }

    // MARK: Rows

    func numberOfRows(in tableView: NSTableView) -> Int { hits.count(of: model.kind) }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: SearchShareCell.reuse, owner: nil) as? SearchShareCell ?? SearchShareCell()
        switch model.kind {
        case .links: cell.show(hits.links[row])
        case .files: cell.show(hits.files[row])
        case .threads: cell.show(hits.threads[row])
        case .photos: break
        }
        if row >= hits.count(of: model.kind) - 20 { model.loadMore() }
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        tableView.makeView(withIdentifier: ChatRowView.reuse, owner: nil) as? ChatRowView
            ?? { let view = ChatRowView(); view.identifier = ChatRowView.reuse; return view }()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        guard row >= 0 else { return }
        let target: SearchTarget? = switch model.kind {
        case .links: hits.links.indices.contains(row) ? hits.links[row].target : nil
        case .files: hits.files.indices.contains(row) ? hits.files[row].target : nil
        case .threads: hits.threads.indices.contains(row) ? hits.threads[row].target : nil
        case .photos: nil
        }
        guard let target else { return }
        onOpen?(target)
        if case .link = target { table.deselectAll(nil) }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = table.clickedRow
        guard model.kind == .links, hits.links.indices.contains(row) else { return }
        for item in SearchViews.menu(for: hits.links[row], open: { [weak self] target in self?.onOpen?(target) }).items {
            item.menu?.removeItem(item)
            menu.addItem(item)
        }
    }
}
