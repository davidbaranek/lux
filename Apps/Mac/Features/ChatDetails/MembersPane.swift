import AppKit
import LuxCore

/// A group's members in the details: a search field over a list of their pictures, names and
/// roles, the account first.
final class MembersPane: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let model: MembersModel
    private let images: ImagePipeline?
    private var observation: AnyObject?
    private let search = NSSearchField()
    private let table = NSTableView()
    private let empty = NSTextField(labelWithString: "")

    init(model: MembersModel, images: ImagePipeline?) {
        self.model = model
        self.images = images
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        search.placeholderString = String(localized: "Search Members")
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.target = self
        search.action = #selector(searched)
        table.addTableColumn(NSTableColumn(identifier: .init("member")))
        table.headerView = nil
        table.rowHeight = 36
        table.style = .plain
        table.intercellSpacing = NSSize(width: 0, height: table.intercellSpacing.height)
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityIdentifier("members")
        let scroll = NSScrollView()
        scroll.documentView = table
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
            search.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: ChatDetailsController.inset),
            search.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -ChatDetailsController.inset),
            search.topAnchor.constraint(equalTo: container.topAnchor),
            // every tab's content starts at the same inset as the Info form's.
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: ChatDetailsController.inset),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -ChatDetailsController.inset),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
        view = container
        observation = model.changes.observe { [weak self] in self?.update() }
        update()
        Task { await model.load() }
    }

    private func update() {
        table.reloadData()
        empty.stringValue = model.isLoading ? String(localized: "Loading…")
            : model.failure?.localizedDescription ?? String(localized: "No Members Found")
        empty.isHidden = !model.found.isEmpty
        search.placeholderString = model.isLoading ? String(localized: "Search Members")
            : String(localized: "Search \(model.count) Members")
    }

    @objc private func searched() {
        model.search(search.stringValue)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { model.found.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: MemberCellView.identifier, owner: nil) as? MemberCellView ?? MemberCellView()
        if let member = model.found[safe: row] { cell.show(member, images: images) }
        return cell
    }
}

/// A member's row: their picture, their name, and their role.
private final class MemberCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("member")
    private let avatar = AvatarView(side: 26)
    private let name = NSTextField(labelWithString: "")
    private let role = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        name.lineBreakMode = .byTruncatingTail
        role.textColor = .secondaryLabelColor
        role.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        role.setContentHuggingPriority(.required, for: .horizontal)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        avatar.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: [avatar, name, role])
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: 26),
            avatar.heightAnchor.constraint(equalToConstant: 26),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(_ member: ChatMember, images: ImagePipeline?) {
        avatar.show(member.avatar, name: member.name, images: images)
        name.stringValue = member.isOwn ? String(localized: "\(member.name) (You)") : member.name
        name.toolTip = member.id
        role.stringValue = member.role.title ?? ""
        setAccessibilityLabel([name.stringValue, member.role.title].compactMap { $0 }.joined(separator: ", "))
    }
}
