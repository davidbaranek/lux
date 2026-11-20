import AppKit
import LuxCore

/// One chat: a table of recycled message rows over a diffable data source, a glass composer, and a
/// right-click menu with reactions. Every row is measured off the main thread before it shows
/// (`MessageLayoutCache`); the table gets exact heights and the rows only place their parts. A
/// Matrix thread of the chat shows the same way, in the window's inspector beside the chat:
/// its root, its replies, the composer replying there.
final class ThreadController: NSViewController, NSTableViewDelegate, NSTextViewDelegate, NSMenuItemValidation {
    let session: Session
    let row: ChatRow
    /// The screen's logic, shared with the iPhone: opening, measuring, jumping, being on screen.
    let presenter: ThreadPresenter
    var model: ThreadModel { presenter.model }
    /// The screen's own work (downloads for Quick Look, the benchmark): it ends with the screen.
    let tasks = TaskBag()
    var messages: [String: MessageItem] = [:]
    /// The rows' ids, as the applied snapshot has them.
    private(set) var order: [String] = []
    let table = MessageTableView()
    let scroll = NSScrollView()
    /// Holds the place an update moves it to while the update goes in.
    private let clip = MessageClipView()
    private var dataSource: NSTableViewDiffableDataSource<Int, String>!
    /// The composer's text, as tall as what is written up to a few lines.
    let composerField = ComposerField(font: .systemFont(ofSize: NSFont.systemFontSize + 1))
    /// The text view the user writes in (the window's first responder while the chat has the keyboard).
    var field: ComposerTextView { composerField.textView }
    /// Called once the first messages (or "No messages") are drawn.
    var onReady: (() -> Void)?
    /// A merged chat now shows another of its rooms, or all.
    var onShownRoom: (() -> Void)?
    /// A thread's summary or "Reply in Thread" asks for the Matrix thread a message starts.
    var onOpenThread: ((MatrixThread, MessageLink?) -> Void)?
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
    /// The typing line's views, which show and go together.
    var typingViews: [NSView] { [typingGlass, typing, typingAvatar] }
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
    /// The chat's pinned messages, over its top.
    private let newPinBar = NewPinBar()
    /// The pins changed: the chat's details, when they show beside it, list them.
    var onPinned: (([PinnedMessage]) -> Void)?
    /// Shows while messages come from the server (the opening fill, older messages).
    private let loading = LoadingBubble(text: String(localized: "Loading messages"))
    private let empty = NSTextField(labelWithString: String(localized: "No messages"))
    private var shownFirst: Bool { presenter.shownFirst }
    private var layouts: [String: MessageLayout] = [:]
    /// The scrolls the presenter asked for: only the last one's glide tells its end.
    private var scrolls = 0
    /// The message a jump brought into view: its row flashes (`MessageCellView.isJumpTarget`).
    private var highlighted: String?
    private let text = MessageText()
    /// The inspector is opening or closing beside the chat: the chat resizes live, as it does
    /// while the user drags the window's edge.
    var resizesLive = false {
        didSet { if !resizesLive { view.needsLayout = true } }
    }
    /// While the chat resizes live, on every frame only the messages on screen are measured for
    /// the new width, right away, so they narrow or widen with it; all of them are measured once,
    /// off the main thread, when it ends.
    private var isResizingLive: Bool { resizesLive || view.inLiveResize }

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

    /// `focus`: a message to scroll to once the chat shows (a saved one).
    /// The shown place's colour, for one's own bubbles (the pane behind the chat washes in it too).
    /// Neutral keeps the system's accent.
    var theme: PlaceTheme {
        didSet { if theme != oldValue, isViewLoaded { updateTheme() } }
    }
    private var accent: NSColor { theme.color ?? .controlAccentColor }

    /// The chat of `row`, or its Matrix thread `thread`.
    init(session: Session, row: ChatRow, theme: PlaceTheme, focus: MessageLink? = nil, thread: MatrixThread? = nil) {
        self.session = session
        self.row = row
        self.theme = theme
        presenter = ThreadPresenter(session: session, row: row, thread: thread, focus: focus)
        super.init(nibName: nil, bundle: nil)
        presenter.screen = self
        presenter.measure(with: text)
    }

    /// The Matrix thread `message` starts (a new one, to reply in, if it starts none), beside the
    /// chat.
    func openThread(of message: MessageItem) {
        guard model.thread == nil, !message.eventId.isEmpty else { return }
        onOpenThread?(MatrixThread(roomId: message.roomId, rootEventId: message.eventId), nil)
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
        // a file dragged out goes as a copy.
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        // a two-finger swipe to the right answers a message.
        table.canReply = { [weak self] row in
            guard let self, row < order.count, let message = messages[order[row]] else { return false }
            return MessageAction.available(for: message, inThread: model.thread != nil).contains(.reply)
        }
        table.reply = { [weak self] row in
            guard let self, row < order.count, let message = messages[order[row]] else { return }
            model.reply(to: message)
        }
        table.onScrollWheel = { [weak self] in self?.presenter.userStartedScrolling() }
        table.setAccessibilityIdentifier("messages")
        scroll.contentView = clip
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = true

        let glass = composer
        glass.cornerRadius = 18
        field.placeholder = model.thread == nil ? String(localized: "Message") : String(localized: "Reply in Thread")
        field.delegate = self
        // a pasted or dropped picture, video or file waits in the composer, as a picked one does.
        field.onAttach = { [weak self] items in self?.attachPasted(items) }
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
        let fieldRow = NSStackView(views: [composerField, sendNetwork])
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
        // a glass capsule behind "Anna is typing…": legible over the messages it floats on.
        // Hidden while no one types: a clear view still takes the clicks over the messages.
        for view in typingViews {
            view.alphaValue = 0
            view.isHidden = true
        }
        for view in [scroll, attach, glass, eye, jumpToBottom, jumpToUnread, typingGlass, typing, typingAvatar, newPinBar] as [NSView] {
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
            // at most a third of the chat: past it, the text scrolls inside.
            composerField.heightAnchor.constraint(lessThanOrEqualTo: container.heightAnchor, multiplier: 1 / 3),
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
            newPinBar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            newPinBar.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),
            newPinBar.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 8),
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
        // the live resize ended: every message is measured for the width it ended at.
        container.onEndLiveResize = { [weak self] in self?.view.needsLayout = true }
        view = container
        updateTheme()

        let images = session.images
        dataSource = NSTableViewDiffableDataSource(tableView: table) { [weak self] table, _, _, id in
            let cell = table.makeView(withIdentifier: MessageCellView.reuse, owner: nil) as? MessageCellView ?? MessageCellView()
            if let self { cell.accent = accent }
            if let self, let message = messages[id], let layout = layouts[id] {
                cell.show(message, layout: layout, isGroup: row.isGroup, text: text, images: images)
            }
            // the jump's message flashes, also when its row shows later.
            cell.isJumpTarget = self?.highlighted == id
            cell.onLink = { NSWorkspace.shared.open($0) }
            cell.onBubbleTap = { [weak self] in
                guard let self, let message = messages[id] else { return }
                model.tap(message)
            }
            cell.onReactionTap = { [weak self] key in self?.model.toggleReaction(key, on: id) }
            cell.onPostMore = { [weak self] in self?.presenter.togglePost(of: id) }
            // a shared post's card (its title and caption) opens the post; its media opens as any.
            cell.onPostOpen = self?.messages[id]?.shared?.link.map { post in { NSWorkspace.shared.open(post) } }
            cell.onMediaTap = self?.messages[id]?.hasMedia == true ? { [weak self, weak cell] index in
                guard let self, let message = messages[id] else { return }
                openMedia(message, at: index, from: cell?.mediaFrameOnScreen(at: index))
            } : nil
            cell.menuProvider = { [weak self] in self?.menu(for: id) }
            cell.onQuoteTap = self?.messages[id]?.quote == nil ? nil : { [weak self] in self?.presenter.jump(toRepliedMessageOf: id) }
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
        presenter.onLoading = { [weak self] loading in
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
        // a video goes smaller unless the user chooses Original in its tile.
        model.pendingVideos.onChange = { [weak self] in
            guard let self else { return }
            strip.videos = model.pendingVideos.videos
        }
        strip.onVideoQuality = { [weak self] file, quality in self?.model.pendingVideos.setQuality(quality, of: file) }
        model.onShownRoom = { [weak self] _ in self?.onShownRoom?() }
        model.onReadState = { [weak self] _ in self?.updateEye() }
        model.onTyping = { [weak self] names in self?.showTyping(names) }
        newPinBar.onJump = { [weak self] pin in self?.presenter.jump(toMessage: pin.link) }
        newPinBar.onSeen = { [weak self] in self?.model.pinsSeen() }
        model.onPinned = { [weak self] pinned in
            guard let self else { return }
            newPinBar.show(model.newPin)
            onPinned?(pinned)
        }
        newPinBar.show(model.newPin)
        model.onError = { [weak self] error in self?.report(error, of: "chat") }
        presenter.start()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        presenter.disappeared(draft: composerField.text)
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
            composerField.text = original
        }
        view.window?.makeFirstResponder(field)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // the chat got wider or narrower: measure again for the new width.
        let width = scroll.contentView.bounds.width
        if width > 0, width != presenter.width {
            // a chat still to show its first messages measures them all, live or not.
            if isResizingLive, shownFirst {
                relayoutShown(width: width)
            } else {
                presenter.resize(to: width)
            }
        }
        // the last message ends above the composer, which floats over the chat, and above
        // "Anna is typing…" while it shows.
        let bottom = composer.frame.height + 28 + (typingShown ? typing.intrinsicContentSize.height + 16 : 0)
        guard scroll.contentInsets.bottom != bottom else { return anchorToBottom() }
        // the list stays where the presenter has it: at the newest, the new room included, on the
        // jump's message, or on the row read.
        presenter.keepingPlace {
            scroll.automaticallyAdjustsContentInsets = false
            scroll.contentInsets = NSEdgeInsets(top: view.safeAreaInsets.top, left: 0, bottom: bottom, right: 0)
            anchorToBottom()
        }
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

    override func viewDidAppear() {
        super.viewDidAppear()
        // on screen while its window has the focus; a thread's panel shows beside its chat.
        presenter.appeared()
        view.window?.makeFirstResponder(field)
    }

    /// An empty chat says so, once the server has had its say.
    private func updateEmpty() {
        empty.isHidden = !(model.hasLoaded && !model.isLoading && order.isEmpty)
    }

    /// A photo, video or file dragged out of the chat (to Finder, Mail): its file, once downloaded.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        order.indices.contains(row) ? messages[order[row]].flatMap(filePromise) : nil
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        // `order` mirrors the applied snapshot: an array index, not a data source lookup, for every row.
        order.indices.contains(row) ? layouts[order[row]]?.height ?? 44 : 44
    }

    /// The rows on screen (and a few around them) measured for `width` now, on the main thread:
    /// a handful of messages per frame, while the chat resizes live. The rest keep their size
    /// until the full measure at the end; the reader stays at the bottom, or on the row they read.
    private func relayoutShown(width: CGFloat) {
        guard shownFirst, !order.isEmpty else { return }
        presenter.keepingPlace { relayout(shownRowsFor: width) }
    }

    private func relayout(shownRowsFor width: CGFloat) {
        let shown = table.rows(in: scroll.contentView.bounds)
        let rows = max(0, shown.location - 4)..<min(order.count, NSMaxRange(shown) + 4)
        let firstUnread = model.firstUnreadId, style = model.chatStyle, metrics = presenter.layoutCache.metrics
        var resized = IndexSet()
        for index in rows {
            let id = order[index]
            guard let message = messages[id] else { continue }
            let layout = MessageLayout.make(message, showsSender: row.isGroup, isFirstUnread: id == firstUnread, style: style,
                                            width: width, metrics: metrics, measure: text)
            layouts[id] = layout
            resized.insert(index)
            (table.view(atColumn: 0, row: index, makeIfNecessary: false) as? MessageCellView)?
                .show(message, layout: layout, isGroup: row.isGroup, text: text, images: session.images)
        }
        guard !resized.isEmpty else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            table.noteHeightOfRows(withIndexesChanged: resized)
        }
        anchorToBottom()
    }

    func show(_ new: [MessageItem], layouts: [String: MessageLayout], changed: [String], scroll intent: ScrollIntent) {
        let ids = new.map(\.id)
        defer { updateEmpty() }
        guard ids != order || !changed.isEmpty || !shownFirst else { return place(intent) }
        messages = Dictionary(new.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.layouts = layouts
        order = ids
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(ids)
        let state = Signposts.thread.beginInterval("apply")
        defer { Signposts.thread.endInterval("apply", state, "\(changed.count) changed") }
        // the place holds while the rows go in, past the end of the rows there now; `place(_:)`
        // puts it exactly after.
        clip.holdsPlace = shownFirst
        if shownFirst { preplace(intent, among: ids, layouts: layouts) }
        // no animation: the table would slide rows from their old places and animate new heights,
        // and the chat would visibly shift under the reader; but a caption the user unfolds or
        // folds grows or shrinks before their eyes.
        let unfolds = presenter.takeUnfolding(in: changed)
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
        clip.holdsPlace = false
        let first = !shownFirst
        if first {
            if LaunchOptions.isBenchmark {
                tasks.run { [weak self, scroll] in
                    try await ThreadBenchmark(scroll).open { [weak self] in self?.scrollGeometry.fromBottom ?? 0 }
                    ScrollBenchmark(scroll, name: "chat", direction: -1).run { self?.runThreadBenchmark() }
                }
            }
            if fadesIn {
                // the first messages appear with a quick fade, already in place.
                scroll.alphaValue = 0
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.15
                    scroll.animator().alphaValue = 1
                }
            }
            presenter.didShowFirst()
        }
        anchorToBottom()
        // the one place this update leaves the list, unanimated.
        place(intent)
        if first {
            onReady?()
            onReady = nil
        }
        updateJumpToUnread()
    }

    /// The clip moves, quietly, to where `intent` puts the rows `ids` before they go in (their
    /// heights are exact): the table then lays out only the rows that will be on screen, and makes
    /// no views for rows the reader never sees (where the list was, among rows going in above it,
    /// or a jump's rows replacing the live ones). `place(_:)` puts it exactly once they are in.
    private func preplace(_ intent: ScrollIntent, among ids: [String], layouts: [String: MessageLayout]) {
        let clip = scroll.contentView
        guard let y = scrollGeometry.offset(for: intent, stacking: ids, height: { layouts[$0]?.height ?? 44 }),
              abs(y - clip.bounds.minY) > 0.5 else { return }
        // quietly: told now, the table would lay out the rows before the insert at the new place.
        clip.postsBoundsChangedNotifications = false
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.minX, y: y))
        clip.postsBoundsChangedNotifications = true
    }

    @objc private func userStartedScrolling() {
        presenter.userStartedScrolling()
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
        if shownFirst, let id = model.firstUnreadId, let span = rowSpan(of: id) {
            showUp = scrollGeometry.isAbove(span.maxY)
        }
        jumpToUnread.fade(in: showUp)
    }

    /// Glides to the first unread message, as to a quoted one.
    @objc private func jumpToFirstUnread() {
        presenter.jumpToFirstUnread()
    }

    @objc private func scrolled() {
        let geometry = scrollGeometry
        // a screen or more above the newest message: offer the way back.
        // a jump's rows are not the newest: the way back always shows.
        jumpToBottom.fade(in: shownFirst && (geometry.isScreenAboveBottom || !model.isLive))
        updateJumpToUnread()
        if shownFirst, geometry.fromBottom < 40 { model.didReadLatest() }
    }

    /// A row comes on screen: near the top, older messages are asked for (near a jump's end, newer ones).
    func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
        presenter.displayed(scrollGeometry)
    }

    /// After the chat's scroll (`-LuxBenchmark`): a jump far back while its pages load, then new
    /// messages at the newest.
    private func runThreadBenchmark() {
        guard let room = model.rooms.first?.id else { return }
        tasks.run { [weak self] in
            guard let self else { return }
            try await ThreadBenchmark(scroll).run(
                jump: { presenter.jump(toMessage: MessageLink(roomId: room, eventId: "\(room)/1000")) },
                back: { scrollToNewest() },
                send: { model.send($0) })
        }
    }

    @objc private func scrollToNewest() {
        // a jump's rows give way to the live ones; live rows scroll down.
        presenter.userStartedScrolling()
        guard !order.isEmpty, !presenter.returnToLive() else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.allowsImplicitAnimation = true
            table.scrollRowToVisible(order.count - 1)
        }
    }

    @objc private func sendReadReceipt() { model.sendReadReceipt() }
}

extension ThreadController: ThreadScreen {
    func showDraft(_ text: String) { composerField.text = text }

    var scrollGeometry: ScrollGeometry {
        let clip = scroll.contentView.bounds
        return ScrollGeometry(offset: clip.minY, height: clip.height, contentHeight: table.bounds.height,
                              top: scroll.contentInsets.top, bottom: scroll.contentInsets.bottom)
    }

    func rowSpan(of id: String) -> (minY: CGFloat, maxY: CGFloat)? {
        guard let row = order.firstIndex(of: id) else { return nil }
        let rect = table.rect(ofRow: row)
        return (rect.minY, rect.maxY)
    }

    /// Puts the list where `intent` says, at once: the table follows new messages to the newest
    /// unanimated, as `scrollRowToVisible(_:)` did (only a jump glides).
    func place(_ intent: ScrollIntent) {
        guard let offset = scrollGeometry.offset(for: intent, rowSpan: rowSpan) else { return }
        scrollList(to: offset, animated: false)
    }

    func scrollList(to offset: CGFloat, animated: Bool) {
        let clip = scroll.contentView
        // AppKit ends a replaced animation group too: only the last scroll asked for tells its end.
        scrolls += 1
        let asked = scrolls
        guard animated else {
            clip.scroll(to: NSPoint(x: 0, y: offset))
            return scroll.reflectScrolledClipView(clip)
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.45
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            clip.animator().setBoundsOrigin(NSPoint(x: 0, y: offset))
        }, completionHandler: { [weak self] in
            // AppKit ends its animations on the main thread.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.scroll.reflectScrolledClipView(clip)
                if asked == self.scrolls { self.presenter.didEndScrolling() }
            }
        })
    }

    var readingRow: String? { readingAnchor(in: order)?.id }

    func openThread(_ thread: MatrixThread, at message: MessageLink?) {
        onOpenThread?(thread, message)
    }

    func highlight(_ id: String?) {
        let previous = highlighted
        highlighted = id
        // rows on screen read it again; one shown later reads it as it is made.
        for changed in [previous, id].compactMap(\.self) {
            guard let row = dataSource.row(forItemIdentifier: changed) else { continue }
            (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? MessageCellView)?.isJumpTarget = changed == id
        }
    }
}
