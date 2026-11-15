import LuxCore
import UIKit

/// One chat: messages over a diffable data source keyed by message id, a glass composer that rides
/// the keyboard, and a long-press menu with reactions over a preview of the bubble itself. A
/// Matrix thread of the chat shows the same way, pushed over the chat: its root, its replies, the
/// composer replying there.
///
/// Every row's layout is measured off the main thread before it is shown (`MessageLayoutCache`,
/// as Signal's conversation view does) and reused while the message stays the same; the flow
/// layout gets exact heights, so nothing self-sizes on the main thread while scrolling.
final class ThreadViewController: UIViewController, UICollectionViewDelegateFlowLayout, UICollectionViewDataSourcePrefetching {
    let session: Session
    private let row: ChatRow
    let model: ThreadModel
    var messages: [String: MessageItem] = [:]
    private var layouts: [String: MessageLayout] = [:]
    private var order: [String] = []
    private let layoutCache = MessageLayoutCache()
    private var styleObservation: AnyObject?
    private lazy var text = MessageText(traitCollection)
    private var layoutWidth: CGFloat = 0
    /// The newest update; an older one still measuring is dropped.
    private var generation = 0
    var collectionView: UICollectionView!
    var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private let composer = ComposerView()
    /// Shows while messages come from the server (the opening fill, older messages).
    private let loading = LoadingBubble(text: String(localized: "Loading messages"))
    private let empty = UILabel()
    private var shownFirst = false
    /// The user moved the chat: a first unread message found late no longer moves it.
    private var userScrolled = false
    /// The first unread message came late: the next layout moves the chat to it.
    private var scrollsToLateUnread = false
    /// The message a tap on a quote asked for: scrolled to (and flashed) once it is shown.
    private var jumpTarget: String?
    /// Any emoji as a reaction, from the emoji keyboard.
    let emojiPicker = EmojiPicker()
    /// "Anna is typing…" with her picture, above the composer.
    private let typing = TypingView()
    private var swipeToReply: SwipeToReply?
    /// Back to the newest message, when the reader is a screen or more above it.
    private lazy var jumpToBottom = UIButton(configuration: .glass(), primaryAction: UIAction { [weak self] _ in
        self?.scrollToBottom(animated: true)
    })

    /// Up to the first unread message, while it is above the screen.
    private lazy var jumpToUnread = UIButton(configuration: .glass(), primaryAction: UIAction { [weak self] _ in
        self?.jumpToFirstUnread()
    })

    /// The composer's distance from the screen's bottom edge while no keyboard shows.
    private static let composerFromEdge: CGFloat = 28

    /// A message to open at (a saved one), by its event id.
    private let focusEvent: String?

    /// The colour of the place the chat opened from, for one's own bubbles. Neutral keeps the
    /// system's blue.
    var theme: PlaceTheme {
        didSet {
            guard theme != oldValue, isViewLoaded else { return }
            updateTheme()
        }
    }

    /// The list it was opened from: the details tell which of its places keeps the chat out of
    /// the inbox.
    private weak var list: ChatListModel?

    /// The chat of `row`, or its Matrix thread `thread`.
    init(session: Session, row: ChatRow, theme: PlaceTheme, list: ChatListModel?, focusEvent: String? = nil,
         thread: MatrixThread? = nil) {
        self.session = session
        self.row = row
        self.list = list
        self.theme = theme
        self.focusEvent = focusEvent
        model = ThreadModel(session: session, row: row, thread: thread)
        super.init(nibName: nil, bundle: nil)
        title = thread == nil ? row.name : String(localized: "Thread")
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// The chat's picture and name in a glass capsule, the networks under them.
    private lazy var chatTitle = ChatTitleView(row: row, images: session.images)

    private lazy var media = MediaPresenter(host: self)
    private lazy var attachments = AttachmentPicker(host: self) { [weak self] files in self?.model.attach(files) }

    /// One's own bubbles: the place's colour, else the system's blue.
    private var ownFill: UIColor { theme.color ?? .systemBlue }

    private func updateTheme() {
        for case let cell as MessageCell in collectionView.visibleCells { cell.ownFill = ownFill }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.titleView = chatTitle
        chatTitle.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(openDetails)))
        if model.thread != nil {
            // the chat it is in, under "Thread".
            chatTitle.subtitle = String(localized: "Thread")
        } else if row.isMerged {
            navigationItem.rightBarButtonItem = networksButton
            model.onShownRoom = { [weak self] _ in self?.updateNetworks() }
            updateNetworks()
        }

        let layout = UICollectionViewFlowLayout()
        layout.minimumLineSpacing = 0
        layout.sectionInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        layout.sectionInsetReference = .fromSafeArea
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.keyboardDismissMode = .interactive
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        collectionView.accessibilityIdentifier = "messages"
        view.addSubview(collectionView)
        updateTheme()
        // what scrolls under the bar blurs out gradually, not at a hard edge (the system's default).
        collectionView.topEdgeEffect.style = .soft

        let images = session.images
        let cell = UICollectionView.CellRegistration<MessageCell, String> { [weak self] cell, _, id in
            guard let self, let message = messages[id], let layout = layouts[id] else { return }
            cell.ownFill = ownFill
            cell.show(message, layout: layout, isGroup: row.isGroup, text: text, images: images)
            cell.onQuoteTap = message.quote == nil ? nil : { [weak self] in self?.jump(toRepliedMessageOf: id) }
            cell.onLink = { url in UIApplication.shared.open(url) }
            cell.onBubbleTap = { [weak self] in self?.model.toggleDetail(of: id) }
            cell.onReactionTap = { [weak self] key in self?.model.toggleReaction(key, on: id) }
            cell.onPostMore = { [weak self] in
                self?.unfolding = id
                self?.model.togglePost(of: id)
            }
            // a shared post's card (its title and caption) opens the post; its media opens as any.
            cell.onPostOpen = message.shared?.link.map { post in { UIApplication.shared.open(post) } }
            cell.onThreadTap = message.thread == nil ? nil : { [weak self] in
                guard let self, let message = messages[id] else { return }
                openThread(of: message)
            }
            cell.onMediaTap = message.hasMedia ? { [weak self] view, index in
                guard let self, let message = messages[id] else { return }
                media.open(message, at: index, from: view, model: model)
            } : nil
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: id)
        }
        swipeToReply = SwipeToReply(collectionView, canReply: { [weak self] indexPath in
            guard let message = self?.message(at: indexPath) else { return false }
            return MessageAction.available(for: message, inThread: self?.model.thread != nil).contains(.reply)
        }, reply: { [weak self] indexPath in
            guard let self, let message = message(at: indexPath) else { return }
            model.reply(to: message)
        })
        // the full-width back swipe waits for a swipe that started on a message to fail.
        if let pan = swipeToReply?.pan { navigationController?.interactiveContentPopGestureRecognizer?.require(toFail: pan) }

        loading.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(loading)
        NSLayoutConstraint.activate([
            loading.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loading.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
        ])
        loading.set(visible: true)
        empty.text = String(localized: "No messages")
        empty.textColor = .tertiaryLabel
        empty.font = .preferredFont(forTextStyle: .body)
        empty.isHidden = true
        empty.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(empty)
        NSLayoutConstraint.activate([
            empty.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
        ])

        composer.translatesAutoresizingMaskIntoConstraints = false
        if model.thread != nil { composer.placeholderText = String(localized: "Reply in Thread") }
        composer.onSend = { [weak self] text in
            self?.model.send(text)
            self?.donateSent()
        }
        // holding Send: send later, in a chat that is not end-to-end encrypted.
        composer.attachMenu = attachments.menu
        composer.onRemoveAttachment = { [weak self] file in self?.model.removePending(file) }
        model.onPendingFiles = { [weak self] files in self?.composer.attachments = files }
        // holding Send: send later, and in a merged chat, send through another network.
        composer.sendLaterMenu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in completion(self?.sendChoices() ?? []) },
        ])
        composer.onCancelMode = { [weak self] in self?.model.cancelMode() }
        composer.onReadReceipt = { [weak self] in self?.model.sendReadReceipt() }
        composer.onTextChange = { [weak self] text in self?.model.composerChanged(text) }
        typing.images = session.images
        typing.alpha = 0
        typing.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(typing)
        composer.readReceiptsMenu = UIMenu(title: String(localized: "Read Receipts in This Chat"), children: [
            UIDeferredMenuElement.uncached { [weak self] completion in completion(self?.readReceiptChoices() ?? []) },
        ])
        view.addSubview(composer)
        jumpToBottom.configuration?.image = UIImage(systemName: "chevron.down", withConfiguration: UIImage.SymbolConfiguration(weight: .semibold))
        jumpToBottom.configuration?.cornerStyle = .capsule
        jumpToBottom.accessibilityLabel = String(localized: "Scroll to the newest message")
        jumpToBottom.alpha = 0
        jumpToBottom.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(jumpToBottom)
        jumpToUnread.configuration?.image = UIImage(systemName: "chevron.up", withConfiguration: UIImage.SymbolConfiguration(weight: .semibold))
        jumpToUnread.configuration?.cornerStyle = .capsule
        jumpToUnread.accessibilityLabel = String(localized: "Scroll to the first unread message")
        jumpToUnread.alpha = 0
        jumpToUnread.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(jumpToUnread)
        view.addSubview(emojiPicker)
        view.keyboardLayoutGuide.usesBottomSafeArea = false
        let pullDown = composer.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        pullDown.priority = .defaultLow
        NSLayoutConstraint.activate([
            composer.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            composer.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            // above the keyboard while it shows, else low by the screen's edge, as Messages has it:
            // over the home indicator's band, not on top of it.
            composer.bottomAnchor.constraint(lessThanOrEqualTo: view.keyboardLayoutGuide.topAnchor, constant: -8),
            composer.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -Self.composerFromEdge),
            pullDown,
            // in line with the send button below it (same width, same edge).
            jumpToBottom.trailingAnchor.constraint(equalTo: composer.trailingAnchor),
            jumpToBottom.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -12),
            // in line with the bubbles' edge (`BubbleMetrics.sideMargin`), not their text.
            typing.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: BubbleMetrics().sideMargin),
            typing.trailingAnchor.constraint(lessThanOrEqualTo: jumpToBottom.leadingAnchor, constant: -8),
            typing.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -6),
            jumpToBottom.widthAnchor.constraint(equalToConstant: 44),
            jumpToBottom.heightAnchor.constraint(equalToConstant: 44),
            // above the way down: unread messages are up, the newest down.
            jumpToUnread.trailingAnchor.constraint(equalTo: jumpToBottom.trailingAnchor),
            jumpToUnread.bottomAnchor.constraint(equalTo: jumpToBottom.topAnchor, constant: -10),
            jumpToUnread.widthAnchor.constraint(equalToConstant: 44),
            jumpToUnread.heightAnchor.constraint(equalToConstant: 44),
        ])

        // a new text size measures every message again.
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
            self.text = MessageText(self.traitCollection)
            self.layoutCache.reset()
            self.show(self.model.messages, relayout: true)
        }
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
        model.onReadState = { [weak self] needed in self?.composer.setNeedsReadReceipt(needed) }
        model.onTyping = { [weak self] names in self?.showTyping(names) }
        model.onError = { [weak self] error in self?.report(error, of: "chat") }
        Task {
            composer.text = await model.loadDraft()
            await model.findFirstUnread()
            await model.start()
            if let focusEvent, let target = await model.message(ofEvent: focusEvent) {
                jumpTarget = target
                jumpIfShown()
            }
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        model.watchTyping()
    }

    /// The chat's rooms, whose notifications this chat stands for.
    private var rooms: Set<String> { Set([row.id] + row.rooms.map(\.id)) }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // on screen: no banners for it, and what it notified is seen.
        if let thread = model.thread {
            session.roomsOnScreen = []
            session.threadsOnScreen = [thread.rootEventId]
        } else {
            session.roomsOnScreen = rooms
            session.threadsOnScreen = []
            Task { [rooms] in await PushNotifications.removeDelivered(rooms: rooms) }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.roomsOnScreen == rooms { session.roomsOnScreen = [] }
        if let thread = model.thread { session.threadsOnScreen.remove(thread.rootEventId) }
        model.stopWatchingTyping()
        model.saveDraft(composer.text)
    }

    /// The composer's bar says what sending does; an edit puts the message's text in the field.
    private func showMode(_ mode: ThreadModel.ComposerMode) {
        switch mode {
        case .message:
            composer.clearMode()
        case .reply(let preview):
            composer.setMode(symbol: "arrowshape.turn.up.left", title: String(localized: "Replying to \(preview.senderName)"), detail: preview.body)
            composer.focus()
        case .edit(_, let original):
            composer.setMode(symbol: "pencil", title: String(localized: "Editing"), detail: original)
            composer.text = original
            composer.focus()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // the width changed (rotation, split view): measure again for the new width.
        let width = collectionView.safeAreaLayoutGuide.layoutFrame.width
        if width != layoutWidth, width > 0 {
            layoutWidth = width
            show(model.messages, relayout: true)
        }
        // the messages scroll under the composer, and end above it.
        // while someone types, their line sits between the messages and the composer.
        let typingRoom = model.typists.isEmpty ? 0 : typing.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).height + 6
        let inset = view.bounds.maxY - composer.frame.minY + 8 + typingRoom - view.safeAreaInsets.bottom
        if abs(collectionView.contentInset.bottom - inset) > 0.5 {
            let atBottom = isAtBottom
            collectionView.contentInset.bottom = inset
            collectionView.verticalScrollIndicatorInsets.bottom = inset
            if atBottom { scrollToBottom(animated: false) }
        }
        anchorToBottom()
    }

    /// A chat shorter than the screen sits at its bottom, by the composer (as Messages does): older
    /// messages arriving from the server grow it upwards, and nothing on screen moves down.
    private func anchorToBottom() {
        let content = collectionView.collectionViewLayout.collectionViewContentSize.height
        let visible = collectionView.bounds.height - collectionView.safeAreaInsets.top - collectionView.safeAreaInsets.bottom
            - collectionView.contentInset.bottom
        let top = max(0, visible - content)
        guard abs(collectionView.contentInset.top - top) > 0.5 else { return }
        collectionView.contentInset.top = top
    }

    private var isAtBottom: Bool {
        let visible = collectionView.bounds.height - collectionView.adjustedContentInset.bottom
        return collectionView.contentOffset.y + visible >= collectionView.contentSize.height - 40
    }

    private func scrollToBottom(animated: Bool) {
        guard !order.isEmpty else { return }
        collectionView.scrollToItem(at: IndexPath(item: order.count - 1, section: 0), at: .bottom, animated: animated)
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
        // a message of yours just went out: the chat follows it to the bottom, as Messages does.
        let sentNow = new.last.map { $0.isOwn && messages[$0.id] == nil && shownFirst } ?? false
        let atBottom = isAtBottom || sentNow
        // older messages came in above: keep what is on screen where it is.
        let prepended = order.first.map { first in ids.first != first } ?? false
        messages = Dictionary(new.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.layouts = layouts
        order = ids
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(ids)
        let state = Signposts.thread.beginInterval("apply")
        defer { Signposts.thread.endInterval("apply", state, "\(changed.count) changed") }
        // the first messages (also after an empty first answer) land at the bottom, unanimated.
        if !shownFirst || order.count == ids.count && dataSource.snapshot().numberOfItems == 0 {
            shownFirst = true
            dataSource.applySnapshotUsingReloadData(snapshot)
            collectionView.layoutIfNeeded()
            anchorToBottom()
            scrollToFirstUnreadOrBottom()
            updateJumpToUnread()
            // the first messages appear with a quick fade, already in place.
            collectionView.alpha = 0
            UIView.animate(withDuration: 0.15) { self.collectionView.alpha = 1 }
            if LaunchOptions.isBenchmark {
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    ScrollBenchmark(collectionView, name: "chat", direction: -1).run()
                }
            }
            return
        }
        defer { jumpIfShown() }
        let existing = Set(dataSource.snapshot().itemIdentifiers)
        snapshot.reconfigureItems(changed.filter(existing.contains))
        if prepended {
            let fromBottom = collectionView.contentSize.height - collectionView.contentOffset.y
            dataSource.apply(snapshot, animatingDifferences: false)
            collectionView.collectionViewLayout.invalidateLayout()
            collectionView.layoutIfNeeded()
            anchorToBottom()
            collectionView.contentOffset.y = collectionView.contentSize.height - fromBottom
        } else if let unfolded = unfolding, changed.contains(unfolded) {
            // a caption the user unfolds or folds grows or shrinks before their eyes, the rows
            // below moving with it.
            unfolding = nil
            UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseInOut]) { [self] in
                dataSource.apply(snapshot, animatingDifferences: false)
                collectionView.collectionViewLayout.invalidateLayout()
                collectionView.layoutIfNeeded()
            }
        } else {
            // while the server's pages come in, the chat stays still: no animated inserts or scrolls.
            let animate = !model.isLoading
            dataSource.apply(snapshot, animatingDifferences: animate)
            // a reconfigured row may have a new height: the flow layout asks again.
            if !changed.isEmpty { collectionView.collectionViewLayout.invalidateLayout() }
            collectionView.layoutIfNeeded()
            anchorToBottom()
            if atBottom { scrollToBottom(animated: animate) }
        }
        if scrollsToLateUnread {
            scrollsToLateUnread = false
            scrollToFirstUnreadOrBottom()
        }
        updateJumpToUnread()
        if isAtBottom { model.didReadLatest() }
    }

    /// The first unread message was found after the chat opened: its marker shows, and a chat the
    /// user has not moved yet opens there, as it would have at once.
    private func showLateFirstUnread() {
        scrollsToLateUnread = shownFirst && !userScrolled
        show(model.messages)
    }

    /// A chat opens at its first unread message when there is more than a screen of them, else at
    /// its newest message.
    private func scrollToFirstUnreadOrBottom() {
        guard let id = model.firstUnreadId, let index = order.firstIndex(of: id) else { return scrollToBottom(animated: false) }
        let marker = collectionView.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame.minY ?? 0
        let visible = collectionView.bounds.height - collectionView.adjustedContentInset.top - collectionView.adjustedContentInset.bottom
        if collectionView.contentSize.height - marker > visible {
            collectionView.contentOffset.y = marker - collectionView.adjustedContentInset.top
        } else {
            scrollToBottom(animated: false)
        }
    }

    /// An empty chat says so, once the server has had its say.
    private func updateEmpty() {
        empty.isHidden = !(model.hasLoaded && !model.isLoading && order.isEmpty)
    }

    func collectionView(_ collectionView: UICollectionView, layout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        // `order` mirrors the applied snapshot: an array index, not a data source lookup, for every row.
        let height = order.indices.contains(indexPath.item) ? layouts[order[indexPath.item]]?.height ?? 44 : 44
        return CGSize(width: layoutWidth, height: height)
    }

    /// Photos and senders' pictures a few rows ahead start loading before their rows appear.
    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        guard let images = session.images else { return }
        let items = indexPaths.compactMap { dataSource.itemIdentifier(for: $0).flatMap { messages[$0] } }
        let scale = traitCollection.displayScale, metrics = layoutCache.metrics
        images.prefetch(items.filter(\.album.isEmpty).compactMap(\.photo?.ref), pixels: Int(metrics.photoWidth * scale))
        // an album's tiles at their own size (the grid's columns decide it).
        for item in items where item.album.count > 1 {
            let tile = MessageLayout.albumGrid(count: item.album.count, width: metrics.photoWidth).tiles[0].width
            images.prefetch(item.album.map(\.photo.ref), pixels: Int(tile * scale))
        }
        let avatarSide = model.chatStyle == .plain ? metrics.plainAvatarSide : metrics.avatarSide
        images.prefetch(items.compactMap(\.senderAvatar), pixels: AvatarView.pixels(avatarSide, traitCollection), shape: .circle)
    }

    /// The times to send later, or why not.
    // MARK: A merged chat's networks

    /// All the merged chat's networks together, or one alone; the subtitle says which.
    private lazy var networksButton = UIBarButtonItem(image: UIImage(systemName: "square.stack"), menu: UIMenu(children: [
        UIDeferredMenuElement.uncached { [weak self] completion in completion(self?.networkChoices() ?? []) },
    ]))

    private func networkChoices() -> [UIMenuElement] {
        let all = UIAction(title: String(localized: "All Networks"), image: UIImage(systemName: "square.stack"),
                           state: model.shownRoom == nil ? .on : .off) { [weak self] _ in self?.model.show(room: nil) }
        let rooms = model.rooms.map { room in
            UIAction(title: Networks.name(room.network),
                     subtitle: room.id == model.sendRoom ? String(localized: "New messages go here") : nil,
                     image: NetworkImage.image(room.network),
                     state: model.shownRoom == room.id ? .on : .off) { [weak self] _ in self?.model.show(room: room.id) }
        }
        return [UIMenu(options: .displayInline, children: [all]), UIMenu(options: .displayInline, children: rooms)]
    }

    private func updateNetworks() {
        let shown = model.rooms.first { $0.id == model.shownRoom }
        chatTitle.subtitle = shown.map { Networks.name($0.network) }
            ?? model.rooms.map { Networks.name($0.network) }.joined(separator: " + ")
        networksButton.image = shown.map { NetworkImage.image($0.network).resized(to: 22) } ?? UIImage(systemName: "square.stack")
        networksButton.accessibilityLabel = String(localized: "Networks")
        networksButton.accessibilityValue = chatTitle.subtitle
    }

    /// The Matrix thread `message` starts (a new one, to reply in, if it starts none), pushed
    /// over the chat.
    func openThread(of message: MessageItem) {
        guard model.thread == nil, !message.eventId.isEmpty else { return }
        openThread(MatrixThread(roomId: message.roomId, rootEventId: message.eventId))
    }

    /// A Matrix thread of this chat, pushed over it.
    func openThread(_ thread: MatrixThread) {
        navigationController?.pushViewController(ThreadViewController(session: session, row: row, theme: theme, list: list, thread: thread), animated: true)
    }

    /// The chat's details, from its title, as Messages opens a conversation's.
    @objc private func openDetails() {
        let details = ChatDetailsViewController(session: session, row: row, list: list)
        details.onChange = { [weak self] row in
            self?.chatTitle.show(row, images: self?.session.images)
            if self?.model.thread != nil { self?.chatTitle.subtitle = String(localized: "Thread") }
        }
        details.onOpenThread = { [weak self] thread in self?.openThread(thread) }
        navigationController?.pushViewController(details, animated: true)
    }

    /// A merged chat's composer shows the network a message goes through.
    private func showSendNetwork(_ network: String?) {
        composer.showSendNetwork(network.map { NetworkImage.image($0) }, name: network.map(Networks.name))
    }

    /// The chat as a conversation the user writes in: the share sheet suggests it.
    private func donateSent() {
        let picture = row.avatar.flatMap { session.images?.cached($0, pixels: 120, shape: .circle) }.map(UIImage.init(cgImage:))
        ConversationDonation.sent(chatId: row.id, name: row.name, isGroup: row.isGroup, picture: picture)
    }

    private func sendChoices() -> [UIMenuElement] {
        let later = UIMenu(title: String(localized: "Send Later"), options: .displayInline, children: sendLaterChoices())
        guard model.rooms.count > 1 else { return [later] }
        let via = model.rooms.map { room in
            UIAction(title: Networks.name(room.network), image: NetworkImage.image(room.network),
                     state: room.id == model.sendRoom ? .on : .off) { [weak self] _ in
                guard let self else { return }
                model.send(composer.text, via: room.id)
                composer.text = ""
                donateSent()
            }
        }
        return [UIMenu(title: String(localized: "Send Through"), options: .displayInline, children: via), later]
    }

    private func sendLaterChoices() -> [UIMenuElement] {
        guard model.canSendLater else {
            return [UIAction(title: String(localized: "Not in encrypted chats"), attributes: .disabled) { _ in }]
        }
        return LaterTime.offered().map { time in
            let date = time.date()
            return UIAction(title: time.title, subtitle: TimeText.upcoming(date), image: UIImage(systemName: time.symbol)) { [weak self] _ in
                guard let self else { return }
                model.sendLater(composer.text, at: date)
                composer.text = ""
            }
        }
    }

    // MARK: Jumping to the first unread message

    /// Offers the way up while the first unread message is above the screen.
    private func updateJumpToUnread() {
        var showUp = false
        if shownFirst, let id = model.firstUnreadId, let index = order.firstIndex(of: id),
           let frame = collectionView.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame {
            showUp = frame.maxY <= collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        }
        if showUp != (jumpToUnread.alpha == 1) {
            UIView.animate(withDuration: 0.2) { self.jumpToUnread.alpha = showUp ? 1 : 0 }
        }
    }

    /// Glides to the first unread message, as to a quoted one.
    private func jumpToFirstUnread() {
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

    /// Once the quoted message is in the list: glide it to the middle, then flash it. A far message
    /// is first brought to a screen away, so the glide is always one screen long.
    private func jumpIfShown() {
        guard let target = jumpTarget, let index = order.firstIndex(of: target),
              let frame = collectionView.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame else { return }
        jumpTarget = nil
        let inset = collectionView.adjustedContentInset
        let visible = collectionView.bounds.height - inset.top - inset.bottom
        let lowest = -inset.top, highest = max(lowest, collectionView.contentSize.height + inset.bottom - collectionView.bounds.height)
        let y = min(max(frame.midY - inset.top - visible / 2, lowest), highest)
        let current = collectionView.contentOffset.y
        if abs(y - current) > visible {
            collectionView.contentOffset.y = y + (y < current ? visible : -visible)
            collectionView.layoutIfNeeded()
        }
        // older pages stay put while gliding: one landing above would move the target.
        isJumping = true
        flashOnArrival = target
        if abs(y - collectionView.contentOffset.y) < 1 { return scrollViewDidEndScrollingAnimation(collectionView) }
        collectionView.setContentOffset(CGPoint(x: collectionView.contentOffset.x, y: y), animated: true)
    }

    private var isJumping = false
    private var flashOnArrival: String?

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        isJumping = false
        if let id = flashOnArrival { flash(id) }
        flashOnArrival = nil
    }

    private func flash(_ id: String) {
        guard let index = order.firstIndex(of: id) else { return }
        (collectionView.cellForItem(at: IndexPath(item: index, section: 0)) as? MessageCell)?.flash()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // a screen or more above the newest message: offer the way back.
        let fromBottom = scrollView.contentSize.height + scrollView.adjustedContentInset.bottom - scrollView.contentOffset.y - scrollView.bounds.height
        let showJump = shownFirst && fromBottom > scrollView.bounds.height
        if showJump != (jumpToBottom.alpha == 1) {
            UIView.animate(withDuration: 0.2) { self.jumpToBottom.alpha = showJump ? 1 : 0 }
        }
        updateJumpToUnread()
        // older messages load three screens before the top: they are there before the reader is.
        guard shownFirst, !isJumping, scrollView.contentOffset.y < scrollView.bounds.height * 3, model.canLoadOlder else { return }
        Task { await model.loadOlder() }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        userScrolled = true
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        if isAtBottom { model.didReadLatest() }
    }

    // MARK: Read receipts and typing

    /// Automatically, manually, or as Settings says; the current choice is ticked.
    private func readReceiptChoices() -> [UIMenuElement] {
        let current = model.readReceiptsOverride
        let app = Preferences.shared.sendsReadReceipts ? String(localized: "Automatically") : String(localized: "Manually")
        func choice(_ title: String, _ image: String, _ mode: ReadReceipts?) -> UIAction {
            UIAction(title: title, image: UIImage(systemName: image), state: current == mode ? .on : .off) { [weak self] _ in
                guard let self else { return }
                model.readReceiptsOverride = mode
                if isAtBottom { model.didReadLatest() }
            }
        }
        return [
            choice(String(localized: "Automatically"), "eye", .automatic),
            choice(String(localized: "Manually"), "hand.tap", .manual),
            choice(String(localized: "As in Settings (\(app))"), "gear", nil),
        ]
    }

    private func showTyping(_ typists: [Typist]) {
        let appears = typing.alpha == 0 && !typists.isEmpty
        let goes = typing.alpha > 0 && typists.isEmpty
        typing.show(typists)
        // it comes up from the composer and grows into place, as Messages' bubble does; it goes
        // the same way back.
        if appears { typing.transform = Self.typingAway(typing.bounds) }
        // the list makes room for the line (`viewDidLayoutSubviews`), the newest message with it.
        UIView.animate(withDuration: appears ? 0.45 : 0.25, delay: 0, usingSpringWithDamping: appears ? 0.72 : 1,
                       initialSpringVelocity: 0) {
            self.typing.alpha = typists.isEmpty ? 0 : 1
            self.typing.transform = goes ? Self.typingAway(self.typing.bounds) : .identity
            self.view.setNeedsLayout()
            self.view.layoutIfNeeded()
        } completion: { _ in
            if self.typing.alpha == 0 { self.typing.transform = .identity }
        }
    }

    /// Where the typing line comes from: smaller and lower, its leading bottom corner in place.
    private static func typingAway(_ bounds: CGRect) -> CGAffineTransform {
        let scale: CGFloat = 0.6
        return CGAffineTransform(translationX: -bounds.width * (1 - scale) / 2, y: bounds.height * (1 - scale) / 2 + 6)
            .scaledBy(x: scale, y: scale)
    }

    private func message(at indexPath: IndexPath) -> MessageItem? {
        dataSource.itemIdentifier(for: indexPath).flatMap { messages[$0] }
    }
}

private extension UIImage {
    /// A logo drawn at `side` points with its own colours (a bar button would tint it).
    func resized(to side: CGFloat) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        }.withRenderingMode(.alwaysOriginal)
    }
}
