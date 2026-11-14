import AppKit
import LuxCore

/// Picks a chat (to forward a message to), in a sheet: the inbox, newest first, filtered as you type.
final class ChatPickerController: NSViewController, NSTableViewDelegate, NSSearchFieldDelegate {
    private let session: Session
    private let model: ChatListModel
    private let pick: (ChatRow) -> Void
    private let heading: String
    private var rows: [ChatRow] = []
    private var shown: [ChatRow] = []
    private let table = NSTableView()
    private let search = NSSearchField()
    private var dataSource: NSTableViewDiffableDataSource<Int, String>!
    private var byId: [String: ChatRow] = [:]

    /// `action`: the button that picks the chosen chat ("Forward", "Merge").
    private let action: String

    init(session: Session, title: String, action: String, pick: @escaping (ChatRow) -> Void) {
        self.action = action
        self.session = session
        self.pick = pick
        heading = title
        model = ChatListModel(session: session)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let title = NSTextField(labelWithString: heading)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        search.placeholderString = String(localized: "Search")
        search.delegate = self
        search.target = self
        search.action = #selector(filterChanged)
        table.addTableColumn(NSTableColumn(identifier: .init("chat")))
        table.headerView = nil
        table.rowHeight = 64
        table.style = .inset
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(choose)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        let cancel = NSButton(title: String(localized: "Cancel"), target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let forward = NSButton(title: action, target: self, action: #selector(choose))
        forward.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), cancel, forward])
        let stack = NSStackView(views: [title, search, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        for view in [search, scroll, buttons] { view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true }
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: 420),
            scroll.heightAnchor.constraint(equalToConstant: 380),
        ])
        view = stack

        let images = session.images
        dataSource = NSTableViewDiffableDataSource(tableView: table) { [weak self] table, _, _, id in
            let cell = table.makeView(withIdentifier: ChatCellView.reuse, owner: nil) as? ChatCellView ?? ChatCellView()
            if let row = self?.byId[id] { cell.show(row, images: images) }
            return cell
        }
        model.onUpdate = { [weak self] sections, _ in
            self?.rows = sections.flatMap(\.rows)
            self?.update()
        }
        Task { await model.reload() }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(search)
    }

    @objc private func filterChanged() { update() }

    private func update() {
        let filter = search.stringValue.trimmingCharacters(in: .whitespaces)
        shown = filter.isEmpty ? rows : rows.filter { $0.name.localizedStandardContains(filter) }
        byId = Dictionary(shown.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(shown.map(\.id))
        dataSource.apply(snapshot, animatingDifferences: false)
        if table.selectedRow < 0, !shown.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
    }

    /// Up and down in the search field move through the chats.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            let step = selector == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            let row = min(max(table.selectedRow + step, 0), shown.count - 1)
            table.selectRowIndexes([row], byExtendingSelection: false)
            table.scrollRowToVisible(row)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            choose()
            return true
        default:
            return false
        }
    }

    @objc private func choose() {
        guard table.selectedRow >= 0, let id = dataSource.itemIdentifier(forRow: table.selectedRow), let row = byId[id] else { return }
        pick(row)
        dismiss(nil)
    }

    @objc private func cancel(_ sender: Any?) { dismiss(nil) }
}
