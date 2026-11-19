import AppKit
import LuxCore

/// A chat's pinned messages in its details, the newest pinned first: each its sender's picture,
/// name and time over its text. A click goes to it in the chat; its menu (a right-click) unpins
/// it, where the user may. Seeing the list sees the chat's pins: none is new any more.
final class PinnedPane: NSViewController, NSMenuDelegate {
    private weak var pins: ThreadModel?
    private let images: ImagePipeline?
    private let table = NSTableView()
    private var dataSource: NSTableViewDiffableDataSource<Int, String>!
    private var pinned: [PinnedMessage] = []
    /// A pinned message was picked: the chat goes to it.
    var onJump: ((PinnedMessage) -> Void)?

    init(pins: ThreadModel, images: ImagePipeline?) {
        self.pins = pins
        self.images = images
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let column = NSTableColumn(identifier: .init("pin"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.intercellSpacing = NSSize(width: 0, height: table.intercellSpacing.height)
        table.rowHeight = 52
        table.backgroundColor = .clear
        let images = images
        dataSource = NSTableViewDiffableDataSource(tableView: table) { [weak self] table, _, row, _ in
            let cell = table.makeView(withIdentifier: PinnedRowView.reuse, owner: nil) as? PinnedRowView ?? PinnedRowView()
            if let pin = self?.pinned[safe: row] { cell.show(pin, images: images) }
            return cell
        }
        table.target = self
        table.action = #selector(clicked)
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        table.setAccessibilityIdentifier("pinnedMessages")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            // every tab's content starts at the same inset as the Info form's.
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: ChatDetailsController.inset),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -ChatDetailsController.inset),
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
        show(pinned: pins?.pinned ?? [])
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        pins?.pinsSeen()
    }

    /// The chat's pins changed: a pin or unpin inserts or removes its row; the rows that stay
    /// draw again in place (no `reloadData`).
    func show(pinned: [PinnedMessage]) {
        if !pinned.isEmpty, view.window != nil { pins?.pinsSeen() }
        self.pinned = pinned.reversed()
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(self.pinned.map(\.key))
        dataSource.apply(snapshot, animatingDifferences: false)
        for (row, pin) in self.pinned.enumerated() {
            (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? PinnedRowView)?.show(pin, images: images)
        }
    }

    @objc private func clicked() {
        guard let pin = pinned[safe: table.clickedRow] else { return }
        onJump?(pin)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let pin = pinned[safe: table.clickedRow] else { return }
        let go = NSMenuItem(title: String(localized: "Go to Message"), action: #selector(goTo(_:)), keyEquivalent: "")
        go.representedObject = pin.key
        go.target = self
        menu.addItem(go)
        guard pins?.mayUnpin(pin) == true else { return }
        let unpin = NSMenuItem(title: String(localized: "Unpin"), action: #selector(unpin(_:)), keyEquivalent: "")
        unpin.image = NSImage.symbol("pin.slash", label: String(localized: "Unpin"))
        unpin.representedObject = pin.key
        unpin.target = self
        menu.addItem(unpin)
    }

    @objc private func goTo(_ item: NSMenuItem) {
        guard let pin = pinned.first(where: { $0.key == item.representedObject as? String }) else { return }
        onJump?(pin)
    }

    @objc private func unpin(_ item: NSMenuItem) {
        guard let pin = pinned.first(where: { $0.key == item.representedObject as? String }) else { return }
        pins?.unpin(pin)
    }
}

private extension PinnedMessage {
    /// Its row's identity: its room and event.
    var key: String { roomId + " " + eventId }
}

/// One pinned message: its sender's picture, name and time over its text.
private final class PinnedRowView: NSTableCellView {
    static let reuse = NSUserInterfaceItemIdentifier("pinnedRow")
    private let avatar = AvatarView(side: 32)
    private let name = NSTextField(labelWithString: "")
    private let time = NSTextField(labelWithString: "")
    private let body = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.reuse
        name.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        time.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        time.textColor = .secondaryLabelColor
        time.setContentCompressionResistancePriority(.required, for: .horizontal)
        // one line each, cut short: the row's height is fixed.
        for label in [name, body] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.cell?.wraps = false
            label.cell?.usesSingleLineMode = true
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let top = NSStackView(views: [name, time])
        let text = NSStackView(views: [top, body])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let all = NSStackView(views: [avatar, text])
        all.alignment = .centerY
        all.spacing = 10
        all.translatesAutoresizingMaskIntoConstraints = false
        addSubview(all)
        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: 32),
            avatar.heightAnchor.constraint(equalToConstant: 32),
            all.leadingAnchor.constraint(equalTo: leadingAnchor),
            all.trailingAnchor.constraint(equalTo: trailingAnchor),
            all.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(_ pin: PinnedMessage, images: ImagePipeline?) {
        avatar.show(pin.senderAvatar, name: pin.senderName, images: images)
        name.stringValue = pin.senderName
        time.stringValue = TimeText.list(pin.date)
        body.stringValue = pin.text
        setAccessibilityLabel([String(localized: "Pinned message from \(pin.senderName)"), pin.text, time.stringValue]
            .filter { !$0.isEmpty }.joined(separator: ", "))
    }
}
