import AppKit
import LuxCore

/// The chats in the sidebar: a view-based table over a diffable data source keyed by room id.
/// Row views are recycled by the table; a row renders again only when what it shows changed.
final class ChatListController: NSViewController, NSTableViewDelegate, NSMenuDelegate {
    /// A chat to show (nil: none), and a message in it to scroll to (a saved one).
    var onSelect: ((ChatRow?, _ focusEvent: String?) -> Void)?
    private let session: Session
    private let model: ChatListModel
    private var rows: [String: ChatRow] = [:]
    private var titles: [String: String] = [:]
    private let table = NSTableView()
    /// What the keyboard starts at when the window opens: the chats, not the search field
    /// (which would open search).
    var initialFocus: NSView { table }
    private var scroll: NSScrollView!
    /// Moves the list down under the sync's bubble, and back.
    private var scrollTop: NSLayoutConstraint!
    private var dataSource: NSTableViewDiffableDataSource<String, String>!

    /// The shown place's accent: the selection and the unread times.
    var accent = NSColor.controlAccentColor {
        didSet {
            guard accent != oldValue, isViewLoaded else { return }
            table.enumerateAvailableRowViews { rowView, row in
                (rowView as? ChatRowView)?.accent = accent
                (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? ChatCellView)?.accent = accent
                (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? PinnedGridView)?.accent = accent
            }
        }
    }

    init(session: Session, model: ChatListModel) {
        self.session = session
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLayout() {
        super.viewDidLayout()
        // the bubble stays within the list, however long its line.
        loading.maxWidth = view.bounds.width - 20
    }

    override func loadView() {
        table.addTableColumn(NSTableColumn(identifier: .init("chat")))
        table.headerView = nil
        table.style = .sourceList
        // the rows draw their own selection (ChatRowView): it stays in the accent colour.
        table.selectionHighlightStyle = .regular
        table.intercellSpacing = .zero
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.setAccessibilityIdentifier("chats")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let container = NSView()
        scrollTop = scroll.topAnchor.constraint(equalTo: container.topAnchor)
        for child in [scroll, loading] as [NSView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(child)
        }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollTop,
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            loading.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            loading.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
        ])
        view = container
        self.scroll = scroll
        loading.set(visible: true)
        makeRoom(forLoading: true)
        model.onLoadState = { [weak self] _ in self?.updateActivity() }
        searchOpened = session.searchChanges.observe { [weak self] in self?.followSearch() }
        followSearch()

        let images = session.images
        dataSource = NSTableViewDiffableDataSource(tableView: table) { [weak self] table, _, _, id in
            if id == Self.gridItem {
                let grid = table.makeView(withIdentifier: PinnedGridView.reuse, owner: nil) as? PinnedGridView
                    ?? { let view = PinnedGridView(); view.identifier = PinnedGridView.reuse; return view }()
                grid.onOpen = { [weak self] row in self?.choose(row) }
                grid.menuProvider = { [weak self] row in self?.menu(for: row) }
                grid.accent = self?.accent ?? .controlAccentColor
                grid.show(self?.pinned ?? [], images: images)
                return grid
            }
            let cell = table.makeView(withIdentifier: ChatCellView.reuse, owner: nil) as? ChatCellView ?? ChatCellView()
            cell.accent = self?.accent ?? .controlAccentColor
            if let row = self?.rows[id] { cell.show(row, images: images) }
            cell.onHover = { [weak self] id in self?.model.prefetch(id) }
            return cell
        }
        // the rows keep their selection in the accent colour (ChatRowView).
        dataSource.rowViewProvider = { [weak self] table, _, _ in
            let rowView = table.makeView(withIdentifier: ChatRowView.reuse, owner: nil) as? ChatRowView
                ?? { let view = ChatRowView(); view.identifier = ChatRowView.reuse; return view }()
            rowView.accent = self?.accent ?? .controlAccentColor
            return rowView
        }
        // a space's own spaces head their chats, as a Discord server's categories do.
        dataSource.sectionHeaderViewProvider = { [weak self] table, _, section in
            let header = table.makeView(withIdentifier: SectionHeader.reuse, owner: nil) as? SectionHeader ?? SectionHeader()
            header.title = self?.titles[section]?.uppercased() ?? ""
            return header
        }
        // right click on a chat: read / unread.
        table.menu = NSMenu()
        table.menu?.delegate = self
        model.onUpdate = { [weak self] sections, changed in self?.show(sections, changed: changed) }
        model.onError = { [weak self] error in self?.report(error, of: "chat list") }
        Task { await model.reload() }
    }

    private var shownFirst = false
    /// The first sync's progress, over the top of the list.
    private let loading = LoadingBubble(text: String(localized: "Loading chats…"))
    /// The place the list showed last: another place replaces the list at once, with no animation.
    private var shownPlace: Place?

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if let id = dataSource.itemIdentifier(forRow: row) { return id == Self.gridItem ? PinnedGridView.height(for: pinned.count) : 64 }
        // a section with no title (a place's own chats) keeps a hairline of a header.
        let section = dataSource.sectionIdentifier(forRow: row)
        return section.flatMap { titles[$0] } == nil ? 1 : 34
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        // a waiting message or a request asks in a sheet (`clicked`) and leaves the open chat be.
        guard let id = dataSource.itemIdentifier(forRow: row), id != Self.gridItem, let chat = rows[id] else { return false }
        switch model.destination(of: chat) {
        case .chat, .message: return true
        case .scheduled, .request: return false
        }
    }

    @objc private func clicked() {
        guard table.clickedRow >= 0, let id = dataSource.itemIdentifier(forRow: table.clickedRow), let row = rows[id],
              !tableView(table, shouldSelectRow: table.clickedRow) else { return }
        open(row)
    }

    /// The inbox's pinned chats, drawn by one row (`gridItem`).
    private var pinned: [ChatRow] = []
    private static let gridItem = "pinned-grid"

    /// A chat chosen in the grid: it opens.
    private func choose(_ row: ChatRow) {
        table.deselectAll(nil)
        onSelect?(row, nil)
    }

    /// A row chosen in the list: a chat opens, a saved message opens its chat there, a waiting
    /// message offers not to send it, a request asks first.
    private func open(_ row: ChatRow) {
        switch model.destination(of: row) {
        case .chat(let chat): onSelect?(chat, nil)
        case .message(let chat, let eventId): onSelect?(chat, eventId)
        case .scheduled(let waiting): cancel(waiting, name: row.name)
        case .request(let request): answer(request)
        }
    }

    private func cancel(_ waiting: ScheduledMessage, name: String) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Sends \(TimeText.upcoming(waiting.sendAt)) to \(name)")
        alert.informativeText = waiting.body
        alert.addButton(withTitle: String(localized: "Keep"))
        alert.addButton(withTitle: String(localized: "Don't Send")).hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                if response == .alertSecondButtonReturn { self?.model.cancel(waiting) }
            }
        }
    }

    private func answer(_ row: ChatRow) {
        let alert = NSAlert()
        alert.messageText = row.name
        alert.informativeText = row.preview
        alert.addButton(withTitle: String(localized: "Accept"))
        alert.addButton(withTitle: String(localized: "Decline"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                switch response {
                case .alertFirstButtonReturn: self?.model.answer(request: row.id, accept: true)
                case .alertSecondButtonReturn: self?.model.answer(request: row.id, accept: false)
                default: break
                }
            }
        }
    }

    /// The sync's bubble sits above the chats, not over them: the list moves down under it while it
    /// shows, and back up when it goes.
    private var searchOpened: AnyObject?
    private var indexProgress: AnyObject?
    private var bubbleShown = true

    /// The bubble was clicked: a network's chats while its history arrives, a sign-in for one
    /// signed out.
    var onActivity: ((ListActivity.Action) -> Void)?
    private var networksObservation: AnyObject?

    private func followSearch() {
        networksObservation = session.networks?.changes.observe { [weak self] in self?.updateActivity() }
        indexProgress = session.search?.progressChanges.observe { [weak self] in self?.updateActivity() }
        updateActivity()
    }

    /// The bubble says what the app is doing (connecting, loading chats, preparing search) and
    /// how far it is; the list makes room for it while it shows.
    private func updateActivity() {
        let activity = ListActivity.describe(model.loadState, search: session.search?.progress,
                                             networks: session.networks?.attention ?? [])
        if let activity {
            loading.text = [activity.title, activity.detail].compactMap { $0 }.joined(separator: " · ")
            loading.isWarning = activity.isWarning
            loading.onClick = activity.action.map { action in { [weak self] in self?.onActivity?(action) } }
        }
        guard (activity != nil) != bubbleShown else { return }
        bubbleShown = activity != nil
        loading.set(visible: bubbleShown)
        makeRoom(forLoading: bubbleShown)
    }

    private func makeRoom(forLoading visible: Bool) {
        let top: CGFloat = visible ? 46 : 0
        guard scrollTop.constant != top else { return }
        // the list itself slides (an inset would jump): the constraint animates with the layout.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            scrollTop.animator().constant = top
            view.layoutSubtreeIfNeeded()
        }
    }

    /// A quick cross-fade, from one place's chats to another's.
    private static var fade: CATransition {
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 0.18
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        return fade
    }

    private func show(_ sections: [ChatSection], changed: [String]) {
        let first = !shownFirst
        shownFirst = true
        let samePlace = shownPlace == model.place
        shownPlace = model.place
        let new = sections.flatMap(\.rows)
        rows = Dictionary(new.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let oldPinned = pinned
        pinned = sections.first { $0.style == .grid }?.rows ?? []
        titles = Dictionary(sections.compactMap { section in section.title.map { (section.id, $0) } }, uniquingKeysWith: { first, _ in first })
        var snapshot = NSDiffableDataSourceSnapshot<String, String>()
        for section in sections {
            snapshot.appendSections([section.id])
            // the grid is one row for all its chats.
            snapshot.appendItems(section.style == .grid ? [Self.gridItem] : section.rows.map(\.id), toSection: section.id)
        }
        if pinned != oldPinned, let index = dataSource.row(forItemIdentifier: Self.gridItem) {
            (table.view(atColumn: 0, row: index, makeIfNecessary: false) as? PinnedGridView)?.show(pinned, images: session.images)
            if pinned.count != oldPinned.count { table.noteHeightOfRows(withIndexesChanged: [index]) }
        }
        let state = Signposts.list.beginInterval("apply")
        // a list at its top stays there when newer chats move up (the table would keep the row
        // that was first in view).
        let clip = scroll.contentView
        let atTop = clip.bounds.minY <= -clip.contentInsets.top + 4 || !samePlace
        // the open chat stays selected when it moves (a new message brings it to the top): the
        // table would drop the selection, and with it close the chat.
        let selected = table.selectedRow >= 0 ? dataSource.itemIdentifier(forRow: table.selectedRow) : nil
        applying = true
        if !first, !samePlace {
            // another place: its chats cross-fade in, quickly, in place of the last one's.
            scroll.wantsLayer = true
            scroll.layer?.add(Self.fade, forKey: "place")
        }
        dataSource.apply(snapshot, animatingDifferences: !first && samePlace)
        if let selected, let index = dataSource.row(forItemIdentifier: selected), index != table.selectedRow {
            table.selectRowIndexes([index], byExtendingSelection: false)
        }
        applying = false
        if atTop { table.scrollRowToVisible(0) }
        // a row still on screen whose content changed: update its view in place.
        for id in changed {
            if let index = dataSource.row(forItemIdentifier: id), let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? ChatCellView, let row = rows[id] {
                cell.show(row, images: session.images)
            }
        }
        Signposts.list.endInterval("apply", state, "\(changed.count) changed")
        if first {
            Signposts.firstChatsShown(count: new.count)
            if LaunchOptions.isBenchmark { benchmark(new) }
        }
    }

    /// `-LuxBenchmark`: scroll the list down and back, then open a group (which scrolls itself).
    private func benchmark(_ rows: [ChatRow]) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let scroll = self?.scroll else { return }
            ScrollBenchmark(scroll, name: "chat list", direction: 1).run { [weak self] in
                // the first group the table lists (a pinned one is in the grid, no row of its own).
                guard let self, let index = rows.lazy.filter(\.isGroup).compactMap({ self.dataSource.row(forItemIdentifier: $0.id) }).first
                else { return }
                table.selectRowIndexes([index], byExtendingSelection: false)
            }
        }
    }

    /// The list is applying a new snapshot: selection changes are the table's, not the user's.
    private var applying = false

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !applying else { return }
        guard table.selectedRow >= 0, let row = dataSource.itemIdentifier(forRow: table.selectedRow).flatMap({ rows[$0] }) else {
            onSelect?(nil, nil)
            return
        }
        open(row)
    }

    // MARK: The right-click menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard table.clickedRow >= 0, let id = dataSource.itemIdentifier(forRow: table.clickedRow), let row = rows[id],
              let full = self.menu(for: row) else { return }
        for item in full.items {
            full.removeItem(item)
            menu.addItem(item)
        }
    }

    /// What `ChatChange` offers for the chat, a reminder and its labels in submenus; a saved
    /// message's or a waiting message's own action; none for a request.
    private func menu(for row: ChatRow) -> NSMenu? {
        let menu = NSMenu()
        switch model.destination(of: row) {
        case .request: return nil
        case .message:
            guard let saved = model.saved(of: row) else { return nil }
            let item = NSMenuItem(title: MessageAction.unsave.title, action: #selector(unsave(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = saved
            item.image = NSImage(systemSymbolName: MessageAction.unsave.symbol, accessibilityDescription: nil)
            menu.addItem(item)
            return menu
        case .scheduled(let waiting):
            let item = NSMenuItem(title: String(localized: "Don't Send"), action: #selector(cancelScheduled(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = waiting
            item.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
            menu.addItem(item)
            return menu
        case .chat:
            break
        }
        let changes = ChatChange.available(for: row)
        for change in changes where !change.isDestructive { menu.addItem(item(change, row)) }
        menu.addItem(.separator())
        menu.addItem(remindItem(for: row))
        if !row.isGroup {
            let merge = NSMenuItem(title: String(localized: "Merge With…"), action: #selector(mergeChat(_:)), keyEquivalent: "")
            merge.target = self
            merge.representedObject = row
            merge.image = NSImage(systemSymbolName: "arrow.triangle.merge", accessibilityDescription: nil)
            menu.addItem(merge)
        }
        if row.isMerged {
            let separate = NSMenuItem(title: String(localized: "Separate Chats"), action: #selector(unmergeChat(_:)), keyEquivalent: "")
            separate.target = self
            separate.representedObject = row
            separate.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)
            menu.addItem(separate)
        }
        let labels = NSMenuItem(title: String(localized: "Labels"), action: nil, keyEquivalent: "")
        labels.image = NSImage(systemSymbolName: "tag", accessibilityDescription: nil)
        let submenu = NSMenu()
        for label in model.labels {
            let entry = NSMenuItem(title: label.name, action: #selector(toggleLabel(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = [row.id, label.id]
            entry.state = label.rooms.contains(row.id) ? .on : .off
            submenu.addItem(entry)
        }
        if !model.labels.isEmpty { submenu.addItem(.separator()) }
        let new = NSMenuItem(title: String(localized: "New Label…"), action: #selector(newLabel(_:)), keyEquivalent: "")
        new.target = self
        new.representedObject = row.id
        submenu.addItem(new)
        labels.submenu = submenu
        menu.addItem(labels)
        menu.addItem(NotificationMenu.item(chatId: row.id, current: row.notifications, target: self,
                                           action: #selector(choseNotifications(_:))))
        menu.addItem(.separator())
        for change in changes where change.isDestructive { menu.addItem(item(change, row)) }
        return menu
    }

    private func item(_ change: ChatChange, _ row: ChatRow) -> NSMenuItem {
        let item = NSMenuItem(title: change.title, action: #selector(performChange(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = (row, change)
        item.image = NSImage(systemSymbolName: change.symbol, accessibilityDescription: nil)
        return item
    }

    /// Does a menu's change; deleting asks first.
    @objc private func performChange(_ item: NSMenuItem) {
        guard let (row, change) = item.representedObject as? (ChatRow, ChatChange) else { return }
        guard change.needsConfirmation else { return model.change(row.id, change) }
        let alert = NSAlert()
        alert.messageText = String(localized: "Delete \(row.name)?")
        alert.informativeText = ChatChange.deleteWarning
        alert.addButton(withTitle: String(localized: "Delete")).hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated { if response == .alertFirstButtonReturn { self?.model.change(row.id, change) } }
        }
    }

    /// Remind me to answer: soon, this evening, tomorrow, next week (each with its time); or stop.
    private func remindItem(for row: ChatRow) -> NSMenuItem {
        let title = row.reminder.map { String(localized: "Remind Me · \(TimeText.upcoming($0))") } ?? String(localized: "Remind Me")
        let remind = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        remind.image = NSImage(systemSymbolName: "bell", accessibilityDescription: nil)
        let submenu = NSMenu()
        for time in LaterTime.offered() {
            let date = time.date()
            let entry = NSMenuItem(title: time.title, action: #selector(setReminder(_:)), keyEquivalent: "")
            entry.target = self
            entry.subtitle = TimeText.upcoming(date)
            entry.image = NSImage(systemSymbolName: time.symbol, accessibilityDescription: nil)
            entry.representedObject = Reminder(roomId: row.id, date: date)
            submenu.addItem(entry)
        }
        if row.reminder != nil {
            submenu.addItem(.separator())
            let stop = NSMenuItem(title: String(localized: "Remove Reminder"), action: #selector(setReminder(_:)), keyEquivalent: "")
            stop.target = self
            stop.image = NSImage(systemSymbolName: "bell.slash", accessibilityDescription: nil)
            stop.representedObject = Reminder(roomId: row.id, date: nil)
            submenu.addItem(stop)
        }
        remind.submenu = submenu
        return remind
    }

    /// A menu's reminder: the chat, and when (nil stops it).
    private final class Reminder: NSObject {
        let roomId: String
        let date: Date?
        init(roomId: String, date: Date?) { self.roomId = roomId; self.date = date }
    }

    /// Picks the chat to merge with, in a sheet.
    @objc private func mergeChat(_ item: NSMenuItem) {
        guard let row = item.representedObject as? ChatRow else { return }
        presentAsSheet(ChatPickerController(session: session, title: String(localized: "Merge With"), action: String(localized: "Merge")) { [weak self] other in
            self?.model.merge(row, with: other)
        })
    }

    @objc private func unmergeChat(_ item: NSMenuItem) {
        guard let row = item.representedObject as? ChatRow else { return }
        model.unmerge(row)
    }

    @objc private func setReminder(_ item: NSMenuItem) {
        guard let reminder = item.representedObject as? Reminder else { return }
        model.setReminder(reminder.roomId, at: reminder.date)
    }

    @objc private func unsave(_ item: NSMenuItem) {
        guard let saved = item.representedObject as? SavedMessage else { return }
        model.unsave(saved)
    }

    @objc private func cancelScheduled(_ item: NSMenuItem) {
        guard let waiting = item.representedObject as? ScheduledMessage else { return }
        model.cancel(waiting)
    }

    @objc private func choseNotifications(_ item: NSMenuItem) {
        guard let choice = item.representedObject as? NotificationMenu.Choice, let chatId = choice.chatId else { return }
        model.setNotifications(chatId, choice.setting)
    }

    @objc private func toggleLabel(_ item: NSMenuItem) {
        guard let ids = item.representedObject as? [String], ids.count == 2 else { return }
        model.setChat(ids[0], inLabel: ids[1], item.state != .on)
    }

    @objc private func newLabel(_ item: NSMenuItem) {
        guard let roomId = item.representedObject as? String, let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "New Label")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = String(localized: "Name")
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Create"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                let name = field.stringValue.trimmingCharacters(in: .whitespaces)
                if response == .alertFirstButtonReturn, !name.isEmpty { self?.model.makeLabel(named: name, with: roomId) }
            }
        }
    }
}
