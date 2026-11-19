import AppKit
import LuxCore

/// The sidebar holds the rail and the chats (with the window's traffic lights over the rail); the
/// toolbar spans the chat only, from the sidebar's tracking separator. The inspector, closed until
/// asked for, shows the open chat's details or one of its Matrix threads beside it.
final class MainSplitViewController: NSSplitViewController, NSToolbarDelegate, NSMenuDelegate {
    private let session: Session
    private let sidebarController: SidebarController
    /// The chat list's model: the Settings window sets the places' colour on it.
    var listModel: ChatListModel { sidebarController.listModel }
    var onAccount: (() -> Void)? {
        get { sidebarController.onAccount }
        set { sidebarController.onAccount = newValue }
    }
    /// The inbox's unread chats: the Dock's badge.
    var onBadge: ((Int) -> Void)? {
        get { sidebarController.onBadge }
        set { sidebarController.onBadge = newValue }
    }
    /// The window's own work (a notification's chat, waiting for the list): it ends with the window.
    private let tasks = TaskBag()
    private let detail = ChatContainerController()
    private let inspector = InspectorController()
    private var inspectorItem: NSSplitViewItem!
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
        let inspectorItem = NSSplitViewItem(inspectorWithViewController: inspector)
        // as narrow as Messages' details: a column of settings and lists, not a second chat.
        inspectorItem.minimumThickness = 300
        inspectorItem.maximumThickness = 380
        inspectorItem.isCollapsed = true
        addSplitViewItem(inspectorItem)
        self.inspectorItem = inspectorItem
        sidebarController.onOpen = { [weak self] row, focus in self?.open(row, focus: focus) }
        // a thread search found: its chat, and the thread beside it.
        sidebarController.onOpenThread = { [weak self] row, thread in
            guard let self else { return }
            if openRow?.id != row.id { open(row) }
            showThread(thread)
        }
        sidebarController.onPlaceTitle = { [weak self] title in self?.placeLabel.stringValue = title }
        sidebarController.onTheme = { [weak self] theme in
            self?.detail.theme = theme
            self?.openThread?.theme = theme
            (self?.inspector.shown as? ThreadController)?.theme = theme
        }
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        chatTitle.onClick = { [weak self] in self?.showDetails(nil) }
        inspector.onShow = { [weak self] shown in self?.updateThreadItems(shown) }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// What the keyboard starts at when the window opens: the chats.
    var initialFocus: NSView { sidebarController.initialFocus }

    override func viewDidLayout() {
        super.viewDidLayout()
        alignTitle()
    }

    /// The chat's picture in the toolbar starts where the chat's messages do (the row's side
    /// margin, where a group's pictures are), whatever the toolbar's own spacing, sidebar width
    /// and window.
    private func alignTitle() {
        guard detail.view.window != nil else { return }
        chatTitle.pictureStart = detail.view.convert(NSPoint(x: BubbleMetrics().sideMargin, y: 0), to: nil).x
    }

    private func open(_ row: ChatRow?, focus: MessageLink? = nil) {
        openRow = row
        // the inspector follows the chat: its details for the new one; another chat's thread goes.
        if inspector.shown is ChatDetailsController, let row {
            inspector.show(details(of: row))
        } else {
            closeInspector()
        }
        if let row {
            let thread = ThreadController(session: session, row: row, theme: listModel.theme, focus: focus)
            thread.onShownRoom = { [weak self] in self?.updateNetworks() }
            // its Matrix threads open in the inspector beside it.
            thread.onOpenThread = { [weak self] matrixThread, message in self?.showThread(matrixThread, at: message) }
            // the chat's details beside it list its pinned messages.
            thread.onPinned = { [weak self] pinned in (self?.inspector.shown as? ChatDetailsController)?.show(pinned: pinned) }
            openThread = thread
            (inspector.shown as? ChatDetailsController)?.pins = thread.model
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

    // MARK: The open chat's details

    private var openRow: ChatRow?

    /// The open chat's details in the inspector, or the inspector closed when it shows them (the
    /// info button, a click on the chat's title, View › Chat Details, ⌘I).
    @objc func showDetails(_ sender: Any?) {
        if !inspectorItem.isCollapsed, inspector.shown is ChatDetailsController {
            closeInspector()
            return
        }
        guard let row = openRow else { return }
        inspector.show(details(of: row))
        openInspector()
    }

    private func details(of row: ChatRow) -> ChatDetailsController {
        let controller = ChatDetailsController(session: session, row: row, list: listModel)
        controller.onChange = { [weak self] row in
            guard let self, openRow?.id == row.id else { return }
            chatTitle.show(row, images: session.images)
            view.window?.title = row.name
        }
        controller.onLeave = { [weak self] in self?.open(nil) }
        controller.onOpenThread = { [weak self] thread in self?.showThread(thread) }
        controller.pins = openThread?.model
        controller.onJump = { [weak self] pin in
            guard let chat = self?.openThread else { return }
            chat.presenter.jump(toMessage: pin.link)
            self?.view.window?.makeFirstResponder(chat.field)
        }
        return controller
    }

    /// A Matrix thread of the open chat in the inspector, beside the chat (at one of its messages, if given).
    private func showThread(_ thread: MatrixThread, at message: MessageLink? = nil) {
        guard let row = openRow else { return }
        if let shown = inspector.shown as? ThreadController, shown.model.thread == thread, !inspectorItem.isCollapsed {
            view.window?.makeFirstResponder(shown.field)
            if let message { shown.presenter.jump(toMessage: message) }
            return
        }
        let controller = ThreadController(session: session, row: row, theme: listModel.theme, focus: message, thread: thread)
        inspector.show(controller)
        openInspector()
    }

    private func openInspector() {
        guard inspectorItem.isCollapsed else { return }
        animateInspector(collapsed: false)
    }

    /// Opens or closes the inspector beside the chat, which resizes live as it slides.
    private func animateInspector(collapsed: Bool, then done: (@MainActor () -> Void)? = nil) {
        let chat = openThread
        chat?.resizesLive = true
        NSAnimationContext.runAnimationGroup { _ in
            inspectorItem.animator().isCollapsed = collapsed
        } completionHandler: {
            // AppKit ends an animation group on the main thread.
            MainActor.assumeIsolated {
                chat?.resizesLive = false
                done?()
            }
        }
    }

    /// Closes the inspector; what it showed goes (a thread stops following its timeline).
    private func closeInspector() {
        guard inspector.shown != nil else { return }
        if inspectorItem.isCollapsed {
            inspector.show(nil)
            return
        }
        animateInspector(collapsed: true) { [weak self] in
            guard let self, inspectorItem.isCollapsed else { return }
            inspector.show(nil)
        }
        if let chat = openThread { view.window?.makeFirstResponder(chat.field) }
    }

    /// Opens the chat of a notification the user clicked: the merged chat its room is part of,
    /// else the room's own; a thread's reply, with the thread beside it. Right after launch the
    /// account's chats may not have come yet: it waits for them a few seconds.
    func openChat(roomId: String, thread: String? = nil) {
        guard session.isSignedIn else { return }
        // a newer notification's chat replaces one still waiting for the list.
        tasks.run("notification") { [weak self, listModel] in
            guard let row = await listModel.chat(ofRoom: roomId), let self else { return }
            if openRow?.id != row.id { open(row) }
            if let thread { showThread(MatrixThread(roomId: roomId, rootEventId: thread)) }
        }
    }

    private static func emptyState() -> NSViewController {
        let controller = NSViewController()
        controller.view = EmptyStateView(text: String(localized: "Select a chat"))
        return controller
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // the sidebar button and the filter at the sidebar's right edge, by the chat.
        [Self.placeTitle, .flexibleSpace, Self.newMessage, Self.filter, .toggleSidebar, .sidebarTrackingSeparator, Self.chatTitle, .flexibleSpace, Self.networks,
         .inspectorTrackingSeparator, .flexibleSpace, Self.chatInfo]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [Self.threadTitle, Self.closeThread]
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
        if id == Self.chatInfo {
            // the open chat's details in the inspector, or the inspector closed.
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: String(localized: "Chat Details"))
            item.label = String(localized: "Chat Details")
            item.toolTip = String(localized: "Chat Details (⌘I)")
            item.action = #selector(showDetails(_:))
            item.target = self
            return item
        }
        if id == Self.threadTitle {
            // over a thread in the inspector: "Thread" and its chat's name, as Messages titles it.
            let item = NSToolbarItem(itemIdentifier: id)
            let title = NSTextField(labelWithString: String(localized: "Thread"))
            title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
            threadChatName.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            threadChatName.textColor = .secondaryLabelColor
            threadChatName.lineBreakMode = .byTruncatingTail
            let names = NSStackView(views: [title, threadChatName])
            names.orientation = .vertical
            names.alignment = .leading
            names.spacing = 0
            item.view = names
            item.label = String(localized: "Thread")
            item.isBordered = false
            return item
        }
        if id == Self.closeThread {
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: String(localized: "Close Thread"))
            item.label = String(localized: "Close Thread")
            item.toolTip = String(localized: "Close Thread")
            item.action = #selector(closeThread(_:))
            item.target = self
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
    static let chatInfo = NSToolbarItem.Identifier("chat-info")
    static let threadTitle = NSToolbarItem.Identifier("thread-title")
    static let closeThread = NSToolbarItem.Identifier("close-thread")
    private let threadChatName = NSTextField(labelWithString: "")

    /// A thread in the inspector: its title and close button go in the toolbar over it (after
    /// the inspector's separator, and before the info button), and leave with it. Inserted, not
    /// hidden: a hidden item still keeps its spacing in the toolbar.
    private func updateThreadItems(_ shown: NSViewController?) {
        let thread = shown as? ThreadController
        threadChatName.stringValue = thread?.row.name ?? ""
        let ids = toolbar.items.map(\.itemIdentifier)
        if thread != nil, !ids.contains(Self.threadTitle),
           let separator = ids.firstIndex(of: .inspectorTrackingSeparator), let info = ids.firstIndex(of: Self.chatInfo) {
            toolbar.insertItem(withItemIdentifier: Self.closeThread, at: info)
            toolbar.insertItem(withItemIdentifier: Self.threadTitle, at: separator + 1)
        } else if thread == nil {
            for id in [Self.closeThread, Self.threadTitle] {
                if let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == id }) { toolbar.removeItem(at: index) }
            }
        }
    }

    @objc private func closeThread(_ sender: Any?) { closeInspector() }
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

    /// All chats, or one kind, and their order; the current ones ticked, and the icon filled while a
    /// filter applies.
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
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: String(localized: "Sort By")))
        let currentOrder = sidebarController.listModel.order
        for order in ChatOrder.allCases {
            let entry = NSMenuItem(title: order.title, action: #selector(chooseOrder(_:)), keyEquivalent: "")
            entry.target = self
            entry.image = NSImage(systemSymbolName: order.symbol, accessibilityDescription: nil)
            entry.state = currentOrder == order ? .on : .off
            entry.representedObject = order.rawValue
            menu.addItem(entry)
        }
        item.menu = menu
        item.toolTip = current.map { String(localized: "Showing: \($0.title)") } ?? String(localized: "Show only some chats")
        item.image = NSImage(systemSymbolName: current == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill",
                             accessibilityDescription: String(localized: "Filter"))
    }

    @objc private func chooseOrder(_ sender: NSMenuItem) {
        guard let order = (sender.representedObject as? String).flatMap(ChatOrder.init(rawValue:)) else { return }
        sidebarController.listModel.order = order
        updateFilterItem()
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
