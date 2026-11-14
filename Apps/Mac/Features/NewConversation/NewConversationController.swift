import AppKit
import LuxCore

/// A new conversation, in a sheet over the window: a search field, the chats you have with one
/// person, then people to write to (the server's directory, bridge bots, the bridges' contacts).
/// Return or a double click opens the chosen one; Escape closes. The iPhone's sheet, on the Mac.
final class NewConversationController: NSViewController, NSTableViewDelegate, NSSearchFieldDelegate {
    private enum Section: Hashable { case chats, contacts }
    private enum Item: Hashable { case chat(String), contact(String) }

    private let model: NewConversationModel
    private let images: ImagePipeline?
    private let open: (ChatRow) -> Void
    private let field = NSSearchField()
    private let table = NSTableView()
    private let footer = NSTextField(labelWithString: "")
    private var dataSource: NSTableViewDiffableDataSource<Section, Item>!

    init(session: Session, open: @escaping (ChatRow) -> Void) {
        model = NewConversationModel(session: session)
        images = session.images
        self.open = open
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "New Message")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        field.placeholderString = String(localized: "Name, number or @user:server")
        field.delegate = self
        field.sendsSearchStringImmediately = true
        table.addTableColumn(NSTableColumn(identifier: .init("person")))
        table.headerView = nil
        table.style = .plain
        table.rowHeight = 44
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(chooseSelected)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        footer.textColor = .secondaryLabelColor
        footer.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        // its own line, wrapping: a long note never pushes the buttons out of the sheet.
        footer.lineBreakMode = .byWordWrapping
        footer.maximumNumberOfLines = 2
        footer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let close = NSButton(title: String(localized: "Cancel"), target: self, action: #selector(cancel))
        close.keyEquivalent = "\u{1b}"
        let start = NSButton(title: String(localized: "Open"), target: self, action: #selector(chooseSelected))
        start.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), close, start])
        let content = NSStackView(views: [field, scroll, footer, buttons])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        for view in [field, scroll, footer, buttons] { view.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -32).isActive = true }
        scroll.heightAnchor.constraint(equalToConstant: 360).isActive = true
        content.widthAnchor.constraint(equalToConstant: 440).isActive = true
        view = content

        let images = images
        dataSource = NSTableViewDiffableDataSource(tableView: table) { [weak self] table, _, _, item in
            let cell = table.makeView(withIdentifier: PersonCell.reuse, owner: nil) as? PersonCell ?? PersonCell()
            guard let self else { return cell }
            switch item {
            case .chat(let id):
                if let row = model.chats.first(where: { $0.id == id }) {
                    cell.show(name: row.name, detail: Networks.name(row.network), avatar: row.avatar, images: images)
                }
            case .contact(let id):
                if let contact = model.contacts.first(where: { $0.id == id }) {
                    let network = Networks.name(contact.network)
                    cell.show(name: contact.name, detail: contact.name == contact.identifier ? network : "\(network) · \(contact.identifier)",
                              avatar: contact.avatar, images: images)
                }
            }
            return cell
        }
        dataSource.sectionHeaderViewProvider = { table, _, section in
            let header = table.makeView(withIdentifier: SectionHeader.reuse, owner: nil) as? SectionHeader ?? SectionHeader()
            header.title = section == .chats ? String(localized: "YOUR CHATS") : String(localized: "CONTACTS")
            return header
        }
        model.onUpdate = { [weak self] in self?.update() }
        Task { await model.start() }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(field)
    }

    func controlTextDidChange(_ notification: Notification) {
        model.search(field.stringValue)
    }

    /// ↓ and ↑ in the field move through the list; Return opens.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            let down = selector == #selector(NSResponder.moveDown(_:))
            let rows = (0..<table.numberOfRows).filter { dataSource.itemIdentifier(forRow: $0) != nil }
            guard !rows.isEmpty else { return true }
            let current = rows.firstIndex(of: table.selectedRow) ?? (down ? -1 : rows.count)
            let next = rows[max(0, min(rows.count - 1, current + (down ? 1 : -1)))]
            table.selectRowIndexes([next], byExtendingSelection: false)
            table.scrollRowToVisible(next)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            chooseSelected()
            return true
        default:
            return false
        }
    }

    private func update() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        if !model.chats.isEmpty {
            snapshot.appendSections([.chats])
            snapshot.appendItems(model.chats.map { .chat($0.id) }, toSection: .chats)
        }
        if !model.contacts.isEmpty {
            snapshot.appendSections([.contacts])
            snapshot.appendItems(model.contacts.map { .contact($0.id) }, toSection: .contacts)
        }
        dataSource.apply(snapshot, animatingDifferences: false)
        if table.selectedRow < 0, let first = (0..<table.numberOfRows).first(where: { dataSource.itemIdentifier(forRow: $0) != nil }) {
            table.selectRowIndexes([first], byExtendingSelection: false)
        }
        footer.stringValue = if model.isSearching { String(localized: "Searching…") }
            else if let problem = model.problem { problem }
            else if model.query.isEmpty { String(localized: "Type a name, a number or a Matrix address.") }
            else if snapshot.numberOfItems == 0 { String(localized: "Nobody found. A full @user:server always works.") }
            else { "" }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        dataSource.itemIdentifier(forRow: row) == nil ? 26 : 44
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        dataSource.itemIdentifier(forRow: row) != nil
    }

    @objc private func cancel() { dismiss(nil) }

    /// Opens the chosen chat, or the chat with the chosen contact (made if there is none).
    @objc private func chooseSelected() {
        guard table.selectedRow >= 0, let item = dataSource.itemIdentifier(forRow: table.selectedRow) else { return }
        switch item {
        case .chat(let id):
            guard let row = model.chats.first(where: { $0.id == id }) else { return }
            dismiss(nil)
            open(row)
        case .contact(let id):
            guard let contact = model.contacts.first(where: { $0.id == id }) else { return }
            Task {
                do {
                    let roomId = try await model.start(with: contact)
                    dismiss(nil)
                    open(ChatRow(id: roomId, name: contact.name, preview: "", date: nil, network: contact.network, avatar: contact.avatar))
                } catch {
                    footer.stringValue = String(localized: "Could not start the conversation: \(error.localizedDescription)")
                }
            }
        }
    }
}

/// A person or a chat in the sheet: picture, name, and where they are.
private final class PersonCell: NSTableCellView {
    static let reuse = NSUserInterfaceItemIdentifier("person")
    private let avatar = AvatarView(side: 30)
    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.reuse
        name.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = .secondaryLabelColor
        for label in [name, detail] { label.lineBreakMode = .byTruncatingTail }
        let text = NSStackView(views: [name, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let row = NSStackView(views: [avatar, text])
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: 30),
            avatar.heightAnchor.constraint(equalToConstant: 30),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(name: String, detail: String, avatar ref: ImageRef?, images: ImagePipeline?) {
        self.name.stringValue = name
        self.detail.stringValue = detail
        avatar.show(ref, name: name, images: images)
    }
}
