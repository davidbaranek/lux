import AppKit
import LuxCore

/// A chat's Matrix threads in its details, the latest active first, read back as the user
/// scrolls: each its root's sender and text, how many replied and the last reply, a dot while some
/// are unread. A click opens the thread beside the chat.
final class ThreadsPane: NSViewController, NSTableViewDelegate {
    private let model: ThreadsModel
    private let images: ImagePipeline?
    private var observation: AnyObject?
    private let table = NSTableView()
    private var dataSource: NSTableViewDiffableDataSource<Int, String>!
    private var threads: [String: ListedThread] = [:]
    private let empty = NSTextField(labelWithString: "")
    /// A thread was picked: it opens beside the chat.
    var onOpen: ((MatrixThread) -> Void)?

    init(model: ThreadsModel, images: ImagePipeline?) {
        self.model = model
        self.images = images
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let column = NSTableColumn(identifier: .init("thread"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.intercellSpacing = NSSize(width: 0, height: table.intercellSpacing.height)
        table.rowHeight = 64
        table.backgroundColor = .clear
        table.delegate = self
        let images = images
        dataSource = NSTableViewDiffableDataSource(tableView: table) { [weak self] table, _, _, id in
            let cell = table.makeView(withIdentifier: ThreadRowView.reuse, owner: nil) as? ThreadRowView ?? ThreadRowView()
            if let thread = self?.threads[id] { cell.show(thread, images: images) }
            return cell
        }
        table.target = self
        table.action = #selector(clicked)
        table.setAccessibilityIdentifier("threads")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        empty.textColor = .secondaryLabelColor
        empty.alignment = .center
        for view in [scroll, empty] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false }
        let container = NSView()
        container.addSubview(scroll)
        container.addSubview(empty)
        NSLayoutConstraint.activate([
            // every tab's content starts at the same inset as the Info form's.
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: ChatDetailsController.inset),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -ChatDetailsController.inset),
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        view = container
        observation = model.changes.observe { [weak self] in self?.update() }
        update()
        Task { await model.loadMore() }
    }

    /// A page read back inserts its rows; a thread whose replies or text changed draws again in
    /// place. The rows on screen stay as they are (no `reloadData`).
    private func update() {
        let old = threads
        threads = Dictionary(model.threads.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(model.threads.map(\.id))
        dataSource.apply(snapshot, animatingDifferences: false)
        for (id, thread) in threads where old[id].map({ $0 != thread }) ?? false {
            guard let row = dataSource.row(forItemIdentifier: id) else { continue }
            (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? ThreadRowView)?.show(thread, images: images)
        }
        let none = model.threads.isEmpty
        empty.isHidden = !none
        empty.stringValue = model.isLoading ? String(localized: "Loading…")
            : model.failure?.localizedDescription ?? String(localized: "No threads")
    }

    /// A row near the end of what was read comes on screen: the next page.
    func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
        guard row >= model.threads.count - 5 else { return }
        Task { await model.loadMore() }
    }

    @objc private func clicked() {
        guard model.threads.indices.contains(table.clickedRow) else { return }
        onOpen?(model.threads[table.clickedRow].thread)
    }
}

/// One thread: the root's sender's picture, name and time over its text, then how many replied and
/// the last reply, a dot while some are unread.
private final class ThreadRowView: NSTableCellView {
    static let reuse = NSUserInterfaceItemIdentifier("threadRow")
    private let avatar = AvatarView(side: 32)
    private let name = NSTextField(labelWithString: "")
    private let time = NSTextField(labelWithString: "")
    private let root = NSTextField(labelWithString: "")
    private let replies = NSTextField(labelWithString: "")
    private let dot = NSView()

    init() {
        super.init(frame: .zero)
        identifier = Self.reuse
        name.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        name.lineBreakMode = .byTruncatingTail
        time.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        time.textColor = .secondaryLabelColor
        time.setContentCompressionResistancePriority(.required, for: .horizontal)
        root.lineBreakMode = .byTruncatingTail
        replies.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        replies.lineBreakMode = .byTruncatingTail
        // one line each, cut short: the row's height is fixed.
        for label in [name, root, replies] {
            label.maximumNumberOfLines = 1
            label.cell?.wraps = false
            label.cell?.usesSingleLineMode = true
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        let top = NSStackView(views: [name, time])
        let bottom = NSStackView(views: [replies, dot])
        bottom.spacing = 6
        let text = NSStackView(views: [top, root, bottom])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let all = NSStackView(views: [avatar, text])
        all.alignment = .top
        all.spacing = 10
        all.translatesAutoresizingMaskIntoConstraints = false
        addSubview(all)
        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: 32),
            avatar.heightAnchor.constraint(equalToConstant: 32),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            all.leadingAnchor.constraint(equalTo: leadingAnchor),
            all.trailingAnchor.constraint(equalTo: trailingAnchor),
            all.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(_ thread: ListedThread, images: ImagePipeline?) {
        avatar.show(thread.senderAvatar, name: thread.senderName, images: images)
        name.stringValue = thread.senderName
        time.stringValue = TimeText.list(thread.activity)
        root.stringValue = thread.text
        let summary = thread.summary
        let small = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let words = NSMutableAttributedString(string: summary.countText, attributes: [
            .font: NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.controlAccentColor,
        ])
        if let latest = summary.latestReplyText {
            words.append(NSAttributedString(string: " · " + latest, attributes: [.font: small, .foregroundColor: NSColor.secondaryLabelColor]))
        }
        replies.attributedStringValue = words
        dot.isHidden = summary.unread == 0
        dot.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        setAccessibilityLabel([thread.senderName, thread.text, summary.text,
                               summary.unread > 0 ? String(localized: "\(summary.unread) unread") : nil]
            .compactMap { $0 }.joined(separator: ", "))
    }
}
