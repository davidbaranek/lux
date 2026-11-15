import AppKit
import LuxCore

/// One chat: a table of recycled message rows over a diffable data source, a glass composer, and a
/// right-click menu with reactions. Every row is measured off the main thread before it shows
/// (`MessageLayoutCache`); the table gets exact heights and the rows only place their parts. A
/// Matrix thread of the chat shows the same way, in a panel beside the chat (`ChatSplitController`):
/// its root, its replies, the composer replying there.
final class ThreadController: NSViewController, NSTableViewDelegate, NSTextFieldDelegate, NSMenuItemValidation {
    let session: Session
    private let row: ChatRow
    let model: ThreadModel
    var messages: [String: MessageItem] = [:]
    private var order: [String] = []
    let table = MessageTableView()
    let scroll = NSScrollView()
    private var dataSource: NSTableViewDiffableDataSource<Int, String>!
    let field = NSTextField()
    /// Called once the first messages (or "No messages") are drawn.
    var onReady: (() -> Void)?
    /// A merged chat now shows another of its rooms, or all.
    var onShownRoom: (() -> Void)?
    /// A thread's summary or "Reply in Thread" asks for the Matrix thread a message starts.
    var onOpenThread: ((MatrixThread) -> Void)?
    var rooms: [ChatRoom] { model.rooms }
    var shownRoom: String? { model.shownRoom }
    var sendRoom: String { model.sendRoom }
    var isGroup: Bool { row.isGroup }
    func show(room: String?) { model.show(room: room) }
    /// The first messages fade in; off when the pane fades the whole chat in instead.
    var fadesIn = true
    /// "Anna is typing…", above the composer.
    let typing = NSTextField(labelWithString: "")
    let typingAvatar = AvatarView(side: 18)
    let typingGlass: NSGlassEffectView = {
        let glass = NSGlassEffectView()
        glass.cornerRadius = 13
        return glass
    }()
    /// Sends a read receipt; shown while nothing is written and the chat has unread messages.
    /// Its menu (right click, or holding it) chooses how this chat sends them.
    lazy var eye: NSButton = {
        let button = NSButton(image: NSImage.symbol("eye", label: String(localized: "Send Read Receipt")),
                              target: self, action: #selector(sendReadReceipt))
        button.bezelStyle = .glass
        button.controlSize = .extraLarge
        button.borderShape = .circle
        button.toolTip = String(localized: "Send Read Receipt")
        button.isHidden = true
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        let menu = NSMenu(title: String(localized: "Read Receipts in This Chat"))
        menu.delegate = self
        button.menu = menu
        return button
    }()
    /// Attaches files: the open panel (as File > Attach Files… does).
    private lazy var attach: NSButton = {
        let button = NSButton(image: NSImage.symbol("plus", label: String(localized: "Attach Files")),
                              target: self, action: #selector(attachFiles(_:)))
        button.bezelStyle = .glass
        button.controlSize = .extraLarge
        button.borderShape = .circle
        button.toolTip = String(localized: "Attach Files")
        return button
    }()
    /// The originals Quick Look shows (an album's every photo), the one it opened at, and where
    /// that one is on screen (for the zoom).
    var preview: (files: [URL], opened: Int, frame: NSRect?)?
    private let composer = NSGlassEffectView()
    /// Files waiting to go with the message.
    private let strip = AttachmentStrip()
    private let modeBar = ComposerModeBar()
    /// A merged chat's network a message goes through, at the field's end.
    private let sendNetwork = NSImageView()
    /// Back to the newest message, when the reader is a screen or more above it.
    private lazy var jumpToBottom: NSButton = {
        let button = NSButton(image: NSImage.symbol("chevron.down", label: String(localized: "Scroll to the newest message")),
                              target: self, action: #selector(scrollToNewest))
        button.bezelStyle = .glass
        button.controlSize = .large
        button.isHidden = true
        return button
    }()
    /// Up to the first unread message, while it is above the window.
    private lazy var jumpToUnread: NSButton = {
        let button = NSButton(image: NSImage.symbol("chevron.up", label: String(localized: "Scroll to the first unread message")),
                              target: self, action: #selector(jumpToFirstUnread))
        button.bezelStyle = .glass
        button.controlSize = .large
        button.isHidden = true
        return button
    }()
    /// Shows while messages come from the server (the opening fill, older messages).
    private let loading = LoadingBubble(text: String(localized: "Loading messages"))
    private let empty = NSTextField(labelWithString: String(localized: "No messages"))
    private var shownFirst = false
    /// The user moved the chat: a first unread message found late no longer moves it.
    private var userScrolled = false
    /// The first unread message came late: the next layout moves the chat to it.
    private var scrollsToLateUnread = false
    /// The message a click on a quote asked for: scrolled to (and flashed) once it is shown.
    private var jumpTarget: String?
    private let focusEvent: String?
    private var layouts: [String: MessageLayout] = [:]
    private let layoutCache = MessageLayoutCache()
    private var styleObservation: AnyObject?
    private let text = MessageText()
    private var layoutWidth: CGFloat = 0
    /// The newest update; an older one still measuring is dropped.
    private var generation = 0
    /// The last generation the table shows: until it catches up, the rows on screen are not the
    /// model's, and scrolling asks for no more older messages.
    private var appliedGeneration = 0

    /// The composer's glass: beside the eye while it shows, else to the edge.
    var glassBesideEye: NSLayoutConstraint!
    var glassToEdge: NSLayoutConstraint!

    /// "Anna is typing…" shows: the chat makes room for it.
    var typingShown = false
    /// The typing line's place above the composer: it rises into it as it appears.
    var typingBottom: NSLayoutConstraint!
    /// The capsule around the line clears the composer by a gap; it comes from lower.
    static let typingRest: CGFloat = -14, typingAway: CGFloat = -2

    let emojiPicker = EmojiPicker()

    /// `focusEvent`: a message to scroll to once the chat shows (a saved one).
    /// The shown place's colour, for one's own bubbles (the pane behind the chat washes in it too).
    /// Neutral keeps the system's accent.
    var theme: PlaceTheme {
        didSet { if theme != oldValue, isViewLoaded { updateTheme() } }
    }
    private var accent: NSColor { theme.color ?? .controlAccentColor }

    /// The chat of `row`, or its Matrix thread `thread`.
    init(session: Session, row: ChatRow, theme: PlaceTheme, focusEvent: String? = nil, thread: MatrixThread? = nil) {
        self.session = session
        self.row = row
        self.theme = theme
        self.focusEvent = focusEvent
        model = ThreadModel(session: session, row: row, thread: thread)
        super.init(nibName: nil, bundle: nil)
    }

    /// The Matrix thread `message` starts (a new one, to reply in, if it starts none), beside the
    /// chat.
    func openThread(of message: MessageItem) {
        guard model.thread == nil, !message.eventId.isEmpty else { return }
        onOpenThread?(MatrixThread(roomId: message.roomId, rootEventId: message.eventId))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func updateTheme() {
        modeBar.accent = accent
        table.enumerateAvailableRowViews { rowView, _ in
            (rowView.view(atColumn: 0) as? MessageCellView)?.accent = accent
        }
    }

    override func loadView() {
        let column = NSTableColumn(identifier: .init("message"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.headerView = nil
        // rows span the whole width: the layout keeps its own margins.
        table.style = .plain
        table.usesAutomaticRowHeights = false
        table.selectionHighlightStyle = .none
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.delegate = self
        // a two-finger swipe to the right answers a message.
        table.canReply = { [weak self] row in
            guard let self, row < order.count, let message = messages[order[row]] else { return false }
            return MessageAction.available(for: message, inThread: model.thread != nil).contains(.reply)
        }
        table.reply = { [weak self] row in
            guard let self, row < order.count, let message = messages[order[row]] else { return }
            model.reply(to: message)
        }
        table.onScrollWheel = { [weak self] in self?.userScrolled = true }
        table.setAccessibilityIdentifier("messages")
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = true

        let glass = composer
        glass.cornerRadius = 18
        field.placeholderString = model.thread == nil ? String(localized: "Message") : String(localized: "Reply in Thread")
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: NSFont.systemFontSize + 1)
        field.delegate = self
        field.target = self
        field.action = #selector(send)
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.maximumNumberOfLines = 5
        modeBar.isHidden = true
        modeBar.onCancel = { [weak self] in self?.model.cancelMode() }
        strip.isHidden = true
        strip.onRemove = { [weak self] file in self?.model.removePending(file) }
        // in a merged chat, the network a message goes through, small at the field's end.
        sendNetwork.imageScaling = .scaleProportionallyUpOrDown
        sendNetwork.isHidden = true
        sendNetwork.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            sendNetwork.widthAnchor.constraint(equalToConstant: 16),
            sendNetwork.heightAnchor.constraint(equalToConstant: 16),
        ])
        let fieldRow = NSStackView(views: [field, sendNetwork])
        fieldRow.orientation = .horizontal
        fieldRow.alignment = .centerY
        fieldRow.spacing = 6
        let content = NSStackView(views: [modeBar, strip, fieldRow])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 4
        content.edgeInsets = NSEdgeInsets(top: 9, left: 14, bottom: 9, right: 14)
        glass.contentView = content

        let container = FileDropView()
        // dropped files wait in the composer, as picked ones do.
        container.onDrop = { [weak self] files in
            self?.model.attach(files)
            self?.view.window?.makeFirstResponder(self?.field)
        }
        typing.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        typing.textColor = .secondaryLabelColor
        typing.alphaValue = 0
        typingAvatar.alphaValue = 0
        // a glass capsule behind "Anna is typing…": legible over the messages it floats on.
        typingGlass.alphaValue = 0
        for view in [scroll, attach, glass, eye, jumpToBottom, jumpToUnread, typingGlass, typing, typingAvatar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            attach.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            attach.centerYAnchor.constraint(equalTo: glass.bottomAnchor, constant: -18.5),
            attach.widthAnchor.constraint(equalToConstant: 37),
            attach.heightAnchor.constraint(equalToConstant: 37),
            glass.leadingAnchor.constraint(equalTo: attach.trailingAnchor, constant: 8),
            glass.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
            fieldRow.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -28),
            eye.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            eye.centerYAnchor.constraint(equalTo: glass.bottomAnchor, constant: -18.5),
            // a circle as tall as the one-line composer.
            eye.widthAnchor.constraint(equalToConstant: 37),
            eye.heightAnchor.constraint(equalToConstant: 37),
            modeBar.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -28),
            strip.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -28),
            // in line with the bubbles' edge, not their text.
            typingAvatar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: BubbleMetrics().sideMargin),
            typingAvatar.centerYAnchor.constraint(equalTo: typing.centerYAnchor),
            typingAvatar.widthAnchor.constraint(equalToConstant: 18),
            typingAvatar.heightAnchor.constraint(equalToConstant: 18),
            typing.leadingAnchor.constraint(equalTo: typingAvatar.trailingAnchor, constant: 6),
            typingGlass.leadingAnchor.constraint(equalTo: typingAvatar.leadingAnchor, constant: -4),
            typingGlass.trailingAnchor.constraint(equalTo: typing.trailingAnchor, constant: 10),
            typingGlass.centerYAnchor.constraint(equalTo: typing.centerYAnchor),
            typingGlass.heightAnchor.constraint(equalToConstant: 26),
            {
                typingBottom = typing.bottomAnchor.constraint(equalTo: glass.topAnchor, constant: Self.typingRest)
                return typingBottom
            }(),
            jumpToBottom.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            jumpToBottom.bottomAnchor.constraint(equalTo: glass.topAnchor, constant: -12),
            // above the way down: unread messages are up, the newest down.
            jumpToUnread.centerXAnchor.constraint(equalTo: jumpToBottom.centerXAnchor),
            jumpToUnread.bottomAnchor.constraint(equalTo: jumpToBottom.topAnchor, constant: -8),
        ])
        glassBesideEye = glass.trailingAnchor.constraint(equalTo: eye.leadingAnchor, constant: -8)
        glassToEdge = glass.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16)
        glassToEdge.isActive = true
        loading.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(loading)
        NSLayoutConstraint.activate([
            loading.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            loading.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 10),
        ])
        loading.set(visible: true)
        empty.textColor = .tertiaryLabelColor
        empty.font = .preferredFont(forTextStyle: .title3)
        empty.isHidden = true
        empty.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(empty)
        NSLayoutConstraint.activate([
            empty.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        view = container
        updateTheme()

        let images = session.images
        dataSource = NSTableViewDiffableDataSource(tableView: table) { [weak self] table, _, _, id in
            let cell = table.makeView(withIdentifier: MessageCellView.reuse, owner: nil) as? MessageCellView ?? MessageCellView()
            if let self { cell.accent = accent }
            if let self, let message = messages[id], let layout = layouts[id] {
                cell.show(message, layout: layout, isGroup: row.isGroup, text: text, images: images)
            }
            cell.onLink = { NSWorkspace.shared.open($0) }
            cell.onBubbleTap = { [weak self] in self?.model.toggleDetail(of: id) }
            cell.onPostMore = { [weak self] in
                self?.unfolding = id
                self?.model.togglePost(of: id)
            }
            // a shared post's card (its title and caption) opens the post; its media opens as any.
            cell.onPostOpen = self?.messages[id]?.shared?.link.map { post in { NSWorkspace.shared.open(post) } }
            cell.onMediaTap = self?.messages[id]?.hasMedia == true ? { [weak self, weak cell] index in
                guard let self, let message = messages[id] else { return }
                openMedia(message, at: index, from: cell?.mediaFrameOnScreen(at: index))
            } : nil
            cell.menuProvider = { [weak self] in self?.menu(for: id) }
            cell.onQuoteTap = self?.messages[id]?.quote == nil ? nil : { [weak self] in self?.jump(toRepliedMessageOf: id) }
            cell.onThreadTap = self?.messages[id]?.thread == nil ? nil : { [weak self] in
                guard let self, let message = messages[id] else { return }
                openThread(of: message)
            }
            return cell
        }
        dataSource.defaultRowAnimation = []
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                                               object: scroll.contentView)
        // the scroller dragged (the wheel and the trackpad come through the table).
        NotificationCenter.default.addObserver(self, selector: #selector(userStartedScrolling),
                                               name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        scroll.contentView.postsBoundsChangedNotifications = true
        model.onUpdate = { [weak self] messages in self?.show(messages) }
        // bubbles or plain rows, as the chat or Settings has it: every row is measured again.
        styleObservation = Preferences.shared.chatStyleChanges.observe { [weak self] in
            guard let self else { return }
            show(model.messages, relayout: true)
        }
        model.onFirstUnread = { [weak self] _ in self?.showLateFirstUnread() }
        model.onLoading = { [weak self] loading in
            self?.loading.set(visible: loading)
            self?.updateEmpty()
        }
        model.onMode = { [weak self] mode in self?.showMode(mode) }
        model.onSendRoom = { [weak self] network in self?.showSendNetwork(network) }
        showSendNetwork(model.sendNetwork)
        model.onPendingFiles = { [weak self] files in
            guard let self else { return }
            strip.show(files)
            strip.isHidden = files.isEmpty
            updateEye()
        }
        model.onShownRoom = { [weak self] _ in self?.onShownRoom?() }
        model.onReadState = { [weak self] _ in self?.updateEye() }
        model.onTyping = { [weak self] names in self?.showTyping(names) }
        model.onError = { [weak self] error in self?.report(error, of: "chat") }
        Task {
            field.stringValue = await model.loadDraft()
            await model.findFirstUnread()
            await model.start()
            if let focusEvent, let target = await model.message(ofEvent: focusEvent) {
                jumpTarget = target
                jumpIfShown()
            }
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        if let thread = model.thread {
            session.threadsOnScreen.remove(thread.rootEventId)
        } else if session.roomsOnScreen == notifiedRooms {
            session.roomsOnScreen = []
        }
        model.stopWatchingTyping()
        model.saveDraft(field.stringValue)
    }

    /// The composer's bar says what sending does; an edit puts the message's text in the field.
    private func showMode(_ mode: ThreadModel.ComposerMode) {
        switch mode {
        case .message:
            modeBar.isHidden = true
        case .reply(let preview):
            modeBar.show(symbol: "arrowshape.turn.up.left", title: String(localized: "Replying to \(preview.senderName)"), detail: preview.body)
            modeBar.isHidden = false
        case .edit(_, let original):
            modeBar.show(symbol: "pencil", title: String(localized: "Editing"), detail: original)
            modeBar.isHidden = false
            field.stringValue = original
        }
        view.window?.makeFirstResponder(field)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // the chat got wider or narrower: measure again for the new width.
        let width = scroll.contentView.bounds.width
        if width > 0, width != layoutWidth {
            layoutWidth = width
            show(model.messages, relayout: true)
        }
        // the last message ends above the composer, which floats over the chat, and above
        // "Anna is typing…" while it shows.
        let bottom = composer.frame.height + 28 + (typingShown ? typing.intrinsicContentSize.height + 16 : 0)
        if scroll.contentInsets.bottom != bottom {
            let atBottom = isAtBottom
            scroll.automaticallyAdjustsContentInsets = false
            scroll.contentInsets = NSEdgeInsets(top: view.safeAreaInsets.top, left: 0, bottom: bottom, right: 0)
            // still at the very end, the new room included.
            if atBottom {
                let clip = scroll.contentView
                clip.scroll(to: NSPoint(x: 0, y: max(-scroll.contentInsets.top, table.bounds.height + bottom - clip.bounds.height)))
                scroll.reflectScrolledClipView(clip)
            }
        }
        anchorToBottom()
    }

    /// A chat shorter than the window sits at its bottom, by the composer (as Messages does): older
    /// messages arriving from the server grow it upwards, and nothing on screen moves down.
    private func anchorToBottom() {
        let content = order.isEmpty ? 0 : table.rect(ofRow: order.count - 1).maxY
        let safeTop = view.safeAreaInsets.top
        let visible = scroll.frame.height - safeTop - scroll.contentInsets.bottom
        let top = safeTop + max(0, visible - content)
        guard abs(scroll.contentInsets.top - top) > 0.5 else { return }
        scroll.contentInsets.top = top
    }

    /// The chat's rooms, whose notifications this chat stands for.
    private var notifiedRooms: Set<String> { Set([row.id] + row.rooms.map(\.id)) }

    override func viewDidAppear() {
        super.viewDidAppear()
        // on screen: no notifications for it while its window has the focus, and what it
        // notified is seen. A thread's panel shows beside its chat: both are on screen.
        if let thread = model.thread {
            session.threadsOnScreen.insert(thread.rootEventId)
        } else {
            session.roomsOnScreen = notifiedRooms
            Task { [notifiedRooms] in await PushNotifications.removeDelivered(rooms: notifiedRooms) }
        }
        model.watchTyping()
        view.window?.makeFirstResponder(field)
    }

    private var isAtBottom: Bool {
        let clip = scroll.contentView
        return clip.bounds.maxY >= table.bounds.height + scroll.contentInsets.bottom - 40
    }

    private func scrollToBottom() {
        guard !order.isEmpty else { return }
        table.scrollRowToVisible(order.count - 1)
    }

    /// An empty chat says so, once the server has had its say.
    private func updateEmpty() {
        empty.isHidden = !(model.hasLoaded && !model.isLoading && order.isEmpty)
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        // `order` mirrors the applied snapshot: an array index, not a data source lookup, for every row.
        order.indices.contains(row) ? layouts[order[row]]?.height ?? 44 : 44
    }

    /// Measures `new` off the main thread, then shows it. `relayout`: every row may have a new size.
    private func show(_ new: [MessageItem], relayout: Bool = false) {
        // nothing to draw before the model's first answer (an empty chat is drawn as one).
        guard layoutWidth > 0, model.hasLoaded else { return }
        generation += 1
        let generation = generation, width = layoutWidth, text = text, cache = layoutCache, isGroup = row.isGroup
        let firstUnread = model.firstUnreadId, style = model.chatStyle
        Task {
            let state = Signposts.thread.beginInterval("measure")
            let (layouts, changed) = await Self.measure(new, cache: cache, showsSender: isGroup, firstUnread: firstUnread,
                                                        style: style, width: width, text: text)
            Signposts.thread.endInterval("measure", state, "\(new.count) messages, \(changed.count) changed")
            guard generation == self.generation else { return }
            appliedGeneration = generation
            apply(new, layouts: layouts, changed: relayout ? new.map(\.id) : changed)
        }
    }

    @concurrent
    private static func measure(_ messages: [MessageItem], cache: MessageLayoutCache, showsSender: Bool, firstUnread: String?,
                                style: ChatStyle, width: CGFloat, text: MessageText) async -> ([String: MessageLayout], [String]) {
        cache.update(messages, showsSender: showsSender, firstUnread: firstUnread, style: style, width: width, measure: text)
    }

    /// The message whose shared post's caption the user just unfolded or folded: its next change
    /// animates.
    private var unfolding: String?

    private func apply(_ new: [MessageItem], layouts: [String: MessageLayout], changed: [String]) {
        let ids = new.map(\.id)
        defer { updateEmpty() }
        guard ids != order || !changed.isEmpty || !shownFirst else { return }
        // the first messages (also after an empty first answer) land at the bottom.
        // a message of yours just went out: the chat follows it to the bottom, as Messages does.
        let sentNow = new.last.map { $0.isOwn && messages[$0.id] == nil && shownFirst } ?? false
        let atBottom = !shownFirst || order.isEmpty || isAtBottom || sentNow
        let prepended = order.first.map { ids.first != $0 } ?? false
        let oldOrder = order, oldLayouts = self.layouts
        messages = Dictionary(new.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.layouts = layouts
        order = ids
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(ids)
        let state = Signposts.thread.beginInterval("apply")
        defer { Signposts.thread.endInterval("apply", state, "\(changed.count) changed") }
        // the row the reader is looking at, and where on screen: it stays there whatever changes above it.
        let anchor = shownFirst && !atBottom ? readingAnchor(in: oldOrder) : nil
        // rows going in above the reader: the clip moves down by their height first (and by the
        // change of the old first row, whose run or day may change), so the table lays out only
        // the rows that stay on screen, and makes no views for rows the reader never sees.
        if prepended, shownFirst, let oldFirst = oldOrder.first, let at = ids.firstIndex(of: oldFirst), at > 0 {
            let height = { (id: String) in layouts[id]?.height ?? 44 }
            let above = ids[..<at].reduce(CGFloat(0)) { $0 + height($1) } + height(oldFirst) - (oldLayouts[oldFirst]?.height ?? 44)
            let clip = scroll.contentView
            // quietly: told now, the table would lay out the rows before the insert at the new place.
            clip.postsBoundsChangedNotifications = false
            clip.setBoundsOrigin(NSPoint(x: clip.bounds.minX, y: clip.bounds.minY + above))
            clip.postsBoundsChangedNotifications = true
        }
        defer { jumpIfShown() }
        // no animation: the table would slide rows from their old places and animate new heights,
        // and the chat would visibly shift under the reader; but a caption the user unfolds or
        // folds grows or shrinks before their eyes.
        let unfolds = unfolding.map(changed.contains) ?? false
        if unfolds { unfolding = nil }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = unfolds ? 0.25 : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = unfolds
            // without animating differences the table reloads every row on screen; with them (and
            // no row animation) it inserts and removes only the rows that changed.
            dataSource.apply(snapshot, animatingDifferences: shownFirst)
            // rows still on screen whose content or size changed: place them again, and tell the table.
            var resized = IndexSet()
            for id in changed {
                guard let index = dataSource.row(forItemIdentifier: id), let message = messages[id], let layout = layouts[id] else { continue }
                resized.insert(index)
                (table.view(atColumn: 0, row: index, makeIfNecessary: false) as? MessageCellView)?
                    .show(message, layout: layout, isGroup: row.isGroup, text: text, images: session.images)
            }
            if !resized.isEmpty { table.noteHeightOfRows(withIndexesChanged: resized) }
        }
        if !shownFirst || atBottom {
            if !shownFirst, LaunchOptions.isBenchmark {
                Task { [scroll] in
                    try? await Task.sleep(for: .seconds(2))
                    ScrollBenchmark(scroll, name: "chat", direction: -1).run()
                }
            }
            if !shownFirst, fadesIn {
                // the first messages appear with a quick fade, already in place.
                scroll.alphaValue = 0
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.15
                    scroll.animator().alphaValue = 1
                }
            }
            let first = !shownFirst
            shownFirst = true
            anchorToBottom()
            if first {
                scrollToFirstUnreadOrBottom()
                onReady?()
                onReady = nil
            } else {
                scrollToBottom()
            }
        } else if let anchor {
            anchorToBottom()
            keep(anchor)
        }
        if scrollsToLateUnread {
            scrollsToLateUnread = false
            scrollToFirstUnreadOrBottom()
        }
        updateJumpToUnread()
    }

    /// The first unread message was found after the chat opened: its marker shows, and a chat the
    /// user has not moved yet opens there, as it would have at once.
    private func showLateFirstUnread() {
        scrollsToLateUnread = shownFirst && !userScrolled
        show(model.messages)
    }

    @objc private func userStartedScrolling() {
        userScrolled = true
    }

    /// The first row whose top half is on screen, and how far below the clip's top it starts.
    /// `shown`: the rows the table shows now (the order before the update going in).
    private func readingAnchor(in shown: [String]) -> (id: String, offset: CGFloat)? {
        let clip = scroll.contentView
        let top = clip.bounds.minY + scroll.contentInsets.top
        let row = table.row(at: NSPoint(x: 0, y: max(top, 0)))
        guard shown.indices.contains(row) else { return nil }
        return (shown[row], table.rect(ofRow: row).minY - clip.bounds.minY)
    }

    /// Scrolls so the anchor's row starts where it did, without animation; nothing when it already does.
    private func keep(_ anchor: (id: String, offset: CGFloat)) {
        guard let row = order.firstIndex(of: anchor.id) else { return }
        let clip = scroll.contentView
        let y = table.rect(ofRow: row).minY - anchor.offset
        guard abs(y - clip.bounds.minY) > 0.5 else { return }
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
        scroll.reflectScrolledClipView(clip)
    }

    /// A merged chat's composer shows the network a message goes through.
    private func showSendNetwork(_ network: String?) {
        sendNetwork.image = network.map { NetworkImage.image($0) }
        sendNetwork.isHidden = network == nil
        sendNetwork.toolTip = network.map { String(localized: "Sends through \(Networks.name($0))") }
        sendNetwork.setAccessibilityLabel(sendNetwork.toolTip)
    }

    // MARK: Jumping to the first unread message

    /// Offers the way up while the first unread message is above the window.
    private func updateJumpToUnread() {
        var showUp = false
        if shownFirst, let id = model.firstUnreadId, let row = order.firstIndex(of: id) {
            showUp = table.rect(ofRow: row).maxY <= table.visibleRect.minY + scroll.contentInsets.top
        }
        jumpToUnread.fade(in: showUp)
    }

    /// Glides to the first unread message, as to a quoted one.
    @objc private func jumpToFirstUnread() {
        guard let id = model.firstUnreadId else { return }
        jumpTarget = id
        jumpIfShown()
    }

    // MARK: Jumping to a quoted message

    private func jump(toRepliedMessageOf id: String) {
        Task {
            guard let target = await model.repliedMessage(of: id) else { return }
            jumpTarget = target
            jumpIfShown()
        }
    }

    /// Once the quoted message is in the table: glide it to the middle, then flash it.
    private func jumpIfShown() {
        guard let target = jumpTarget, let row = order.firstIndex(of: target) else { return }
        jumpTarget = nil
        let clip = scroll.contentView
        let rect = table.rect(ofRow: row)
        let y = min(max(rect.midY - clip.bounds.height / 2, -scroll.contentInsets.top),
                    max(table.bounds.height + scroll.contentInsets.bottom - clip.bounds.height, -scroll.contentInsets.top))
        // a far message is first brought to a screen away, so the glide is always one screen long.
        let current = clip.bounds.origin.y, visible = clip.bounds.height
        if abs(y - current) > visible {
            clip.scroll(to: NSPoint(x: 0, y: y + (y < current ? visible : -visible)))
            scroll.reflectScrolledClipView(clip)
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.45
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            clip.animator().setBoundsOrigin(NSPoint(x: 0, y: y))
        }, completionHandler: { [weak self] in
            // AppKit ends its animations on the main thread.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.scroll.reflectScrolledClipView(clip)
                (self.table.view(atColumn: 0, row: row, makeIfNecessary: false) as? MessageCellView)?.flash()
            }
        })
    }

    /// A chat opens at its first unread message when there is more than a screen of them, else at
    /// its newest message.
    private func scrollToFirstUnreadOrBottom() {
        guard let id = model.firstUnreadId, let row = order.firstIndex(of: id) else { return scrollToBottom() }
        let marker = table.rect(ofRow: row).minY
        let visible = scroll.frame.height - scroll.contentInsets.top - scroll.contentInsets.bottom
        if table.bounds.height - marker > visible {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: marker - scroll.contentInsets.top))
            scroll.reflectScrolledClipView(scroll.contentView)
        } else {
            scrollToBottom()
        }
    }

    @objc private func scrolled() {
        let clip = scroll.contentView
        let fromBottom = table.bounds.height + scroll.contentInsets.bottom - clip.bounds.maxY
        // a screen or more above the newest message: offer the way back.
        let showJump = shownFirst && fromBottom > clip.bounds.height
        jumpToBottom.fade(in: showJump)
        updateJumpToUnread()
        if shownFirst, fromBottom < 40 { model.didReadLatest() }
        // older messages load three screens before the top: they are there before the reader is.
        guard shownFirst, appliedGeneration == generation, clip.bounds.minY < clip.bounds.height * 3, model.canLoadOlder else { return }
        Task { await model.loadOlder() }
    }

    @objc private func scrollToNewest() {
        guard !order.isEmpty else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.allowsImplicitAnimation = true
            table.scrollRowToVisible(order.count - 1)
        }
    }

    @objc private func sendReadReceipt() { model.sendReadReceipt() }
}

private extension NSView {
    /// Fades in, or out and then hides, so a faded-out button takes no clicks (AppKit hit-tests
    /// a view whatever its alpha).
    func fade(in shows: Bool) {
        guard shows == isHidden else { return }
        if shows {
            alphaValue = 0
            isHidden = false
            NSAnimationContext.runAnimationGroup { _ in animator().alphaValue = 1 }
        } else {
            NSAnimationContext.runAnimationGroup({ _ in animator().alphaValue = 0 }, completionHandler: { [weak self] in
                MainActor.assumeIsolated { if self?.alphaValue == 0 { self?.isHidden = true } }
            })
        }
    }
}
