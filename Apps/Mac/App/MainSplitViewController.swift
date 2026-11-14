import AppKit
import LuxCore

/// The sidebar holds the rail and the chats (with the window's traffic lights over the rail); the
/// toolbar spans the chat only, from the sidebar's tracking separator.
final class MainSplitViewController: NSSplitViewController, NSToolbarDelegate, NSMenuDelegate {
    private let session: Session
    private let sidebarController: SidebarController
    var onAccount: (() -> Void)? {
        get { sidebarController.onAccount }
        set { sidebarController.onAccount = newValue }
    }
    /// The inbox's unread chats: the Dock's badge.
    var onBadge: ((Int) -> Void)? {
        get { sidebarController.onBadge }
        set { sidebarController.onBadge = newValue }
    }
    private let detail = ChatContainerController()
    let toolbar = NSToolbar(identifier: "main")

    init(session: Session) {
        self.session = session
        sidebarController = SidebarController(session: session)
        super.init(nibName: nil, bundle: nil)
        detail.show(Self.emptyState())
        let sidebar = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebar.minimumThickness = 260 + RailController.width
        sidebar.maximumThickness = 420 + RailController.width
        let content = NSSplitViewItem(viewController: detail)
        content.minimumThickness = 360
        addSplitViewItem(sidebar)
        addSplitViewItem(content)
        sidebarController.onOpen = { [weak self] row, focusEvent in self?.open(row, focusEvent: focusEvent) }
        sidebarController.onPlaceTitle = { [weak self] title in self?.placeLabel.stringValue = title }
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLayout() {
        super.viewDidLayout()
        alignTitle()
    }

    /// The chat's picture in the toolbar starts where the chat's messages do (the row's side
    /// margin, where a group's pictures are), whatever the toolbar's own spacing, sidebar width
    /// and window.
    private func alignTitle() {
        guard !chatTitle.isHidden, chatTitle.window != nil, detail.view.window != nil else { return }
        let messages = detail.view.convert(NSPoint(x: BubbleMetrics().sideMargin, y: 0), to: nil).x
        let title = chatTitle.convert(NSPoint.zero, to: nil).x
        chatTitle.lead(by: max(0, messages - (title - chatTitle.edgeInsets.left)))
    }

    private func open(_ row: ChatRow?, focusEvent: String? = nil) {
        if let row {
            let thread = ThreadController(session: session, row: row, focusEvent: focusEvent)
            thread.onShownRoom = { [weak self] in self?.updateNetworks() }
            openThread = thread
            detail.show(thread)
            view.window?.title = row.name
            chatTitle.show(row, images: session.images)
            alignTitle()
        } else {
            openThread = nil
            detail.show(Self.emptyState())
            view.window?.title = "Lux"
            chatTitle.show(nil, images: nil)
        }
        updateNetworks()
    }

    /// Opens the chat of a notification the user clicked: the merged chat its room is part of,
    /// else the room's own. Right after launch the account's chats may not have come yet: it
    /// waits for them a few seconds.
    func openChat(roomId: String) {
        Task { [weak self] in
            for _ in 0..<20 {
                guard let self, session.isSignedIn else { return }
                if let row = await session.chat(ofRoom: roomId) {
                    open(row)
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private static func emptyState() -> NSViewController {
        let controller = NSViewController()
        controller.view = EmptyStateView(text: String(localized: "Select a chat"))
        return controller
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // the sidebar button and the filter at the sidebar's right edge, by the chat.
        [Self.placeTitle, .flexibleSpace, Self.newMessage, Self.filter, .toggleSidebar, .sidebarTrackingSeparator, Self.chatTitle, .flexibleSpace, Self.networks]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
        if id == Self.placeTitle {
            // where the list is (Inbox, Messenger, a space), by the traffic lights.
            let item = NSToolbarItem(itemIdentifier: id)
            placeLabel.font = .systemFont(ofSize: NSFont.systemFontSize + 2, weight: .semibold)
            placeLabel.lineBreakMode = .byTruncatingTail
            placeLabel.stringValue = sidebarController.placeTitle
            item.view = placeLabel
            item.label = String(localized: "Place")
            return item
        }
        if id == Self.chatTitle {
            // the open chat's picture and name, where the window's title would be.
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = chatTitle
            item.label = String(localized: "Chat")
            // the title itself, not a control: no glass around it.
            item.isBordered = false
            return item
        }
        if id == Self.newMessage {
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: String(localized: "New Message"))
            item.label = String(localized: "New Message")
            item.toolTip = String(localized: "New Message (⌘N)")
            item.action = #selector(newMessage(_:))
            item.target = self
            return item
        }
        if id == Self.networks {
            // a merged chat's networks: all together, or one alone.
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.label = String(localized: "Networks")
            item.toolTip = String(localized: "Show all networks of this chat, or one")
            item.image = NSImage(systemSymbolName: "square.stack", accessibilityDescription: String(localized: "Networks"))
            item.menu = NSMenu()
            item.menu.delegate = self
            networksItem = item
            updateNetworks()
            return item
        }
        guard id == Self.filter else { return NSToolbarItem(itemIdentifier: id) }
        let item = NSMenuToolbarItem(itemIdentifier: id)
        item.label = String(localized: "Filter")
        item.toolTip = String(localized: "Show only some chats")
        item.showsIndicator = false
        filterItem = item
        updateFilterItem()
        return item
    }

    // MARK: Filter (beside the sidebar button, as the iPhone's)

    static let filter = NSToolbarItem.Identifier("filter")
    static let placeTitle = NSToolbarItem.Identifier("place-title")
    static let newMessage = NSToolbarItem.Identifier("new-message")
    static let networks = NSToolbarItem.Identifier("networks")
    static let chatTitle = NSToolbarItem.Identifier("chat-title")
    private let chatTitle = ChatTitleView()

    // MARK: A merged chat's networks

    private weak var openThread: ThreadController?
    private weak var networksItem: NSMenuToolbarItem?

    /// The button shows for a merged chat only; the window's subtitle names its networks, or the
    /// one shown; a group says so.
    private func updateNetworks() {
        guard let thread = openThread else {
            networksItem?.isHidden = true
            chatTitle.subtitle = ""
            return
        }
        let shown = thread.rooms.first { $0.id == thread.shownRoom }
        networksItem?.isHidden = thread.rooms.count < 2
        networksItem?.image = shown.map { NetworkImage.image($0.network) } ?? NSImage(systemSymbolName: "square.stack", accessibilityDescription: nil)
        chatTitle.subtitle = thread.rooms.count > 1
            ? shown.map { Networks.name($0.network) } ?? thread.rooms.map { Networks.name($0.network) }.joined(separator: " + ")
            : thread.isGroup ? String(localized: "Group") : ""
    }

    /// The networks menu, built as it opens: All Networks, then each room's network; the shown one ticked.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu == networksItem?.menu, let thread = openThread else { return }
        menu.removeAllItems()
        let all = NSMenuItem(title: String(localized: "All Networks"), action: #selector(showNetwork(_:)), keyEquivalent: "")
        all.target = self
        all.state = thread.shownRoom == nil ? .on : .off
        all.image = NSImage(systemSymbolName: "square.stack", accessibilityDescription: nil)
        menu.addItem(all)
        menu.addItem(.separator())
        for room in thread.rooms {
            let item = NSMenuItem(title: Networks.name(room.network), action: #selector(showNetwork(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = room.id
            item.state = thread.shownRoom == room.id ? .on : .off
            if let small = NetworkImage.image(room.network).copy() as? NSImage {
                small.size = NSSize(width: 16, height: 16)
                item.image = small
            }
            if room.id == thread.sendRoom { item.subtitle = String(localized: "New messages go here") }
            menu.addItem(item)
        }
    }

    @objc private func showNetwork(_ item: NSMenuItem) {
        openThread?.show(room: item.representedObject as? String)
    }

    /// A new conversation, in a sheet (the toolbar's button, File › New Message, ⌘N).
    @objc func newMessage(_ sender: Any?) {
        presentAsSheet(NewConversationController(session: session) { [weak self] row in self?.open(row) })
    }
    private let placeLabel = NSTextField(labelWithString: "")
    private weak var filterItem: NSMenuToolbarItem?

    /// All chats, or one kind; the current one ticked, and the icon filled while one applies.
    private func updateFilterItem() {
        guard let item = filterItem else { return }
        let current = sidebarController.listModel.filter
        let menu = NSMenu()
        func entry(_ title: String, _ symbol: String, _ filter: ChatFilter?) -> NSMenuItem {
            let entry = NSMenuItem(title: title, action: #selector(chooseFilter(_:)), keyEquivalent: "")
            entry.target = self
            entry.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            entry.state = current == filter ? .on : .off
            entry.representedObject = filter?.rawValue
            return entry
        }
        menu.addItem(entry(String(localized: "All Chats"), "tray.full", nil))
        menu.addItem(.separator())
        for (index, filter) in ChatFilter.allCases.enumerated() {
            if index == 2 { menu.addItem(.separator()) }
            menu.addItem(entry(filter.title, filter.symbol, filter))
        }
        item.menu = menu
        item.toolTip = current.map { String(localized: "Showing: \($0.title)") } ?? String(localized: "Show only some chats")
        item.image = NSImage(systemSymbolName: current == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill",
                             accessibilityDescription: String(localized: "Filter"))
    }

    @objc private func chooseFilter(_ sender: NSMenuItem) {
        sidebarController.listModel.filter = (sender.representedObject as? String).flatMap(ChatFilter.init(rawValue:))
        updateFilterItem()
    }
}

final class EmptyStateView: NSView {
    init(text: String) {
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: text)
        label.textColor = .tertiaryLabelColor
        label.font = .preferredFont(forTextStyle: .title3)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}
