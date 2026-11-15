import AppKit
import LuxCore

/// What a chat shared, of one kind, in the details, the newest first and read back as the user
/// scrolls: photos and videos as a grid of squares, files and links as rows, under a search field
/// that keeps those that hold its words (photos also by the words in them and how they look, from
/// photo search). A click opens a photo, video or file in its app, a link in the browser.
final class SharedPane: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegate {
    private let model: SharedModel
    private let images: ImagePipeline?
    private var observation: AnyObject?
    private let search = NSSearchField()
    private let collection = NSCollectionView()
    private let empty = NSTextField(labelWithString: "")
    private var scrolled: NSObjectProtocol?

    init(model: SharedModel, images: ImagePipeline?) {
        self.model = model
        self.images = images
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        search.placeholderString = String(localized: "Search \(model.kind.title)")
        search.sendsSearchStringImmediately = true
        search.target = self
        search.action = #selector(searched)
        collection.collectionViewLayout = layout()
        collection.dataSource = self
        collection.delegate = self
        collection.isSelectable = true
        collection.backgroundColors = [.clear]
        collection.register(SharedTileItem.self, forItemWithIdentifier: SharedTileItem.identifier)
        collection.register(SharedRowItem.self, forItemWithIdentifier: SharedRowItem.identifier)
        collection.setAccessibilityIdentifier("shared")
        let scroll = NSScrollView()
        scroll.documentView = collection
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        empty.textColor = .secondaryLabelColor
        empty.alignment = .center
        for view in [search, scroll, empty] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false }
        let container = NSView()
        container.addSubview(search)
        container.addSubview(scroll)
        container.addSubview(empty)
        NSLayoutConstraint.activate([
            search.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            search.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            search.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
        view = container
        // near the end of what was read, the next page.
        scroll.contentView.postsBoundsChangedNotifications = true
        scrolled = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.loadMoreIfNearEnd() }
        }
        observation = model.changes.observe { [weak self] in self?.update() }
        update()
        Task { await model.loadMore() }
    }

    isolated deinit {
        if let scrolled { NotificationCenter.default.removeObserver(scrolled) }
    }

    /// Three squares across for media; full-width rows for the others.
    private func layout() -> NSCollectionViewLayout {
        let media = model.kind == .media
        let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(media ? 1.0 / 3 : 1), heightDimension: media ? .fractionalWidth(1.0 / 3) : .absolute(44)))
        item.contentInsets = media ? NSDirectionalEdgeInsets(top: 1, leading: 1, bottom: 1, trailing: 1) : .init()
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1), heightDimension: media ? .fractionalWidth(1.0 / 3) : .absolute(44)),
                                                       subitems: [item])
        return NSCollectionViewCompositionalLayout(section: NSCollectionLayoutSection(group: group))
    }

    private func update() {
        collection.reloadData()
        empty.isHidden = !model.items.isEmpty
        let none = switch model.kind {
        case .media: String(localized: "No photos or videos yet")
        case .files: String(localized: "No files yet")
        case .links: String(localized: "No links yet")
        }
        let found = model.query.isEmpty ? none : String(localized: "No Results for “\(model.query)”")
        empty.stringValue = model.isLoading ? String(localized: "Loading…") : model.failure?.localizedDescription ?? found
        // a long stretch that shared nothing of this kind: read on until the pane fills or the start.
        if !model.isLoading, !model.isComplete, model.failure == nil, model.items.count < 18 {
            Task { await model.loadMore() }
        }
    }

    @objc private func searched() {
        let (model, text) = (model, search.stringValue)
        // a newer search makes this one's stale in the model.
        Task { await model.search(text) }
    }

    private func loadMoreIfNearEnd() {
        guard let scroll = collection.enclosingScrollView else { return }
        let visible = scroll.contentView.bounds
        if visible.maxY > collection.frame.height - visible.height { Task { await model.loadMore() } }
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { model.items.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = model.items[indexPath.item]
        if model.kind == .media {
            let tile = collectionView.makeItem(withIdentifier: SharedTileItem.identifier, for: indexPath)
            (tile as? SharedTileItem)?.show(item, images: images)
            return tile
        }
        let row = collectionView.makeItem(withIdentifier: SharedRowItem.identifier, for: indexPath)
        (row as? SharedRowItem)?.show(item)
        return row
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        collectionView.deselectItems(at: indexPaths)
        guard let index = indexPaths.first?.item, let item = model.items[safe: index] else { return }
        if case .link(let url, _) = item.content {
            NSWorkspace.shared.open(url)
            return
        }
        Task {
            do {
                NSWorkspace.shared.open(try await model.file(of: item))
            } catch {
                report(error, of: "shared file")
            }
        }
    }
}

/// A photo's or a video's square; a video shows its length.
private final class SharedTileItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("shared-tile")
    private let picture = RemoteImageView()
    private let length = NSTextField(labelWithString: "")

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        picture.frame = container.bounds
        picture.autoresizingMask = [.width, .height]
        container.addSubview(picture)
        length.font = .systemFont(ofSize: 10, weight: .semibold)
        length.textColor = .white
        length.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(length)
        NSLayoutConstraint.activate([
            length.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            length.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -3),
        ])
        view = container
    }

    func show(_ item: SharedItem, images: ImagePipeline?) {
        picture.show(item.picture?.ref, pixels: 240, images: images)
        if case .video(_, let duration) = item.content {
            length.stringValue = duration.map { Duration.seconds($0).formatted(.time(pattern: .minuteSecond)) } ?? String(localized: "Video")
        } else {
            length.stringValue = ""
        }
        view.toolTip = "\(item.senderName), \(item.date.formatted(date: .abbreviated, time: .shortened))"
    }
}

/// A file's or a link's row: its symbol, its name or host, and who shared it when (or the text
/// around the link).
private final class SharedRowItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("shared-row")
    private let symbol = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    override func loadView() {
        name.lineBreakMode = .byTruncatingMiddle
        detail.lineBreakMode = .byTruncatingTail
        detail.textColor = .secondaryLabelColor
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        for label in [name, detail] { label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        symbol.symbolConfiguration = .init(pointSize: 15, weight: .regular)
        symbol.contentTintColor = .secondaryLabelColor
        let lines = NSStackView(views: [name, detail])
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 1
        let stack = NSStackView(views: [symbol, lines])
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            symbol.widthAnchor.constraint(equalToConstant: 20),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -2),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        view = container
    }

    func show(_ item: SharedItem) {
        switch item.content {
        case .file(let name, let size, _):
            symbol.image = NSImage(systemSymbolName: "doc.fill", accessibilityDescription: nil)
            self.name.stringValue = name
            detail.stringValue = [size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) },
                                  item.senderName, item.date.formatted(date: .abbreviated, time: .omitted)]
                .compactMap { $0 }.joined(separator: " · ")
        case .link(let url, let text):
            symbol.image = NSImage(systemSymbolName: "link", accessibilityDescription: nil)
            name.stringValue = url.shownAddress
            detail.stringValue = text
            view.toolTip = url.absoluteString
        case .photo, .video:
            break
        }
    }
}
