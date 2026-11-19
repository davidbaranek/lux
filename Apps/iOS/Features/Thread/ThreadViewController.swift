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
    /// The screen's logic, shared with the Mac: opening, measuring, jumping, being on screen.
    private let presenter: ThreadPresenter
    var model: ThreadModel { presenter.model }
    var messages: [String: MessageItem] = [:]
    private var layouts: [String: MessageLayout] = [:]
    private var order: [String] = []
    private lazy var text = MessageText(traitCollection)
    /// The screen's own work (the benchmark): it ends with the screen.
    private let tasks = TaskBag()
    var collectionView: UICollectionView!
    var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private let composer = ComposerView()
    /// Shows while messages come from the server (the opening fill, older messages).
    private let loading = LoadingBubble(text: String(localized: "Loading messages"))
    private let empty = UILabel()
    /// Any emoji as a reaction, from the emoji keyboard.
    let emojiPicker = EmojiPicker()
    /// "Anna is typing…" with her picture, above the composer.
    private let typing = TypingView()
    private let newPinBar = NewPinBar()
    /// The chat's details, while they show: they list its pinned messages.
    private weak var shownDetails: ChatDetailsViewController?
    private var swipeToReply: SwipeToReply?
    /// Where the presenter's glide ends, while it goes.
    private var glideEnd: CGFloat?
    /// The message a jump brought into view: its cell flashes (`MessageCell.isJumpTarget`).
    private var highlighted: String?
    /// Back to the newest message, when the reader is a screen or more above it.
    private lazy var jumpToBottom = UIButton(configuration: .glass(), primaryAction: UIAction { [weak self] _ in
        // a jump's rows give way to the live ones; live rows scroll down.
        guard let self else { return }
        presenter.userStartedScrolling()
        guard !presenter.returnToLive() else { return }
        scrollToBottom(animated: true)
    })

    /// Up to the first unread message, while it is above the screen.
    private lazy var jumpToUnread = UIButton(configuration: .glass(), primaryAction: UIAction { [weak self] _ in
        self?.presenter.jumpToFirstUnread()
    })

    /// The composer's distance from the screen's bottom edge while no keyboard shows.
    private static let composerFromEdge: CGFloat = 28

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
    init(session: Session, row: ChatRow, theme: PlaceTheme, list: ChatListModel?, focus: MessageLink? = nil,
         thread: MatrixThread? = nil) {
        self.session = session
        self.row = row
        self.list = list
        self.theme = theme
        presenter = ThreadPresenter(session: session, row: row, thread: thread, focus: focus)
        super.init(nibName: nil, bundle: nil)
        presenter.screen = self
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
            // the jump's message flashes, also when its cell shows later or is configured again.
            cell.configurationUpdateHandler = { [weak self] cell, _ in
                (cell as? MessageCell)?.isJumpTarget = self?.highlighted == id
            }
            cell.onQuoteTap = message.quote == nil ? nil : { [weak self] in self?.presenter.jump(toRepliedMessageOf: id) }
            cell.onLink = { url in UIApplication.shared.open(url) }
            cell.onBubbleTap = { [weak self] in
                guard let self, let message = messages[id] else { return }
                model.tap(message)
            }
            cell.onReactionTap = { [weak self] key in self?.model.toggleReaction(key, on: id) }
            cell.onPostMore = { [weak self] in self?.presenter.togglePost(of: id) }
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
        // a message pinned since the user last saw the chat's pins, over its top.
        newPinBar.translatesAutoresizingMaskIntoConstraints = false
        newPinBar.onJump = { [weak self] pin in self?.presenter.jump(toMessage: pin.link) }
        newPinBar.onSeen = { [weak self] in self?.model.pinsSeen() }
        view.addSubview(newPinBar)
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
            newPinBar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            newPinBar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            newPinBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),
        ])

        // a new text size measures every message again.
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
            self.text = MessageText(self.traitCollection)
            self.presenter.measure(with: self.text)
        }
        presenter.measure(with: text)
        presenter.onLoading = { [weak self] loading in
            self?.loading.set(visible: loading)
            self?.updateEmpty()
        }
        model.onMode = { [weak self] mode in self?.showMode(mode) }
        model.onSendRoom = { [weak self] network in self?.showSendNetwork(network) }
        showSendNetwork(model.sendNetwork)
        model.onReadState = { [weak self] needed in self?.composer.setNeedsReadReceipt(needed) }
        model.onTyping = { [weak self] names in self?.showTyping(names) }
        model.onPinned = { [weak self] pinned in
            guard let self else { return }
            newPinBar.show(model.newPin)
            shownDetails?.show(pinned: pinned)
        }
        newPinBar.show(model.newPin)
        model.onError = { [weak self] error in self?.report(error, of: "chat") }
        presenter.start()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        presenter.appeared()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        presenter.disappeared(draft: composer.text)
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
        presenter.resize(to: collectionView.safeAreaLayoutGuide.layoutFrame.width)
        // the messages scroll under the composer, and end above it.
        // while someone types, their line sits between the messages and the composer.
        let typingRoom = model.typists.isEmpty ? 0 : typing.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).height + 6
        let inset = view.bounds.maxY - composer.frame.minY + 8 + typingRoom - view.safeAreaInsets.bottom
        guard abs(collectionView.contentInset.bottom - inset) > 0.5 else { return anchorToBottom() }
        // the list stays where the presenter has it: at the newest, on the jump's message, or on
        // the row read.
        presenter.keepingPlace {
            collectionView.contentInset.bottom = inset
            collectionView.verticalScrollIndicatorInsets.bottom = inset
            anchorToBottom()
        }
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

    private var isAtBottom: Bool { scrollGeometry.isAtBottom }

    private func scrollToBottom(animated: Bool) {
        guard !order.isEmpty else { return }
        collectionView.scrollToItem(at: IndexPath(item: order.count - 1, section: 0), at: .bottom, animated: animated)
    }

    func show(_ new: [MessageItem], layouts: [String: MessageLayout], changed: [String], scroll: ScrollIntent) {
        let ids = new.map(\.id)
        let shownFirst = presenter.shownFirst
        defer { updateEmpty() }
        guard ids != order || !changed.isEmpty || !shownFirst else { return place(scroll) }
        // older messages came in above: they go in unanimated, the reader's row kept in place.
        let prepended = order.first.map { first in ids.first != first } ?? false
        messages = Dictionary(new.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.layouts = layouts
        order = ids
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(ids)
        let state = Signposts.thread.beginInterval("apply")
        defer { Signposts.thread.endInterval("apply", state, "\(changed.count) changed") }
        // the first messages (also after an empty first answer) go in unanimated, where the chat opens.
        if !shownFirst || dataSource.snapshot().numberOfItems == 0 {
            presenter.didShowFirst()
            dataSource.applySnapshotUsingReloadData(snapshot)
            collectionView.layoutIfNeeded()
            anchorToBottom()
            place(scroll)
            updateJumpToUnread()
            // the first messages appear with a quick fade, already in place.
            collectionView.alpha = 0
            UIView.animate(withDuration: 0.15) { self.collectionView.alpha = 1 }
            if LaunchOptions.isBenchmark {
                tasks.run { [weak self] in
                    try await ThreadBenchmark().open { [weak self] in self?.scrollGeometry.fromBottom ?? 0 }
                    guard let self else { return }
                    ScrollBenchmark(collectionView, name: "chat", direction: -1).run { [weak self] in self?.runThreadBenchmark() }
                }
            }
            return
        }
        let existing = Set(dataSource.snapshot().itemIdentifiers)
        snapshot.reconfigureItems(changed.filter(existing.contains))
        if presenter.takeUnfolding(in: changed) {
            // a caption the user unfolds or folds grows or shrinks before their eyes, the rows
            // below (and the list's place) moving with it.
            UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseInOut]) { [self] in
                dataSource.apply(snapshot, animatingDifferences: false)
                collectionView.collectionViewLayout.invalidateLayout()
                collectionView.layoutIfNeeded()
                anchorToBottom()
                place(scroll)
            }
        } else {
            // while the server's pages come in, the rows switch, or older rows go in above the
            // reader, the chat stays still: no animated inserts.
            let animates = !model.isLoading && !presenter.isSwitching && !prepended
            if !animates { preplace(scroll, among: ids) }
            dataSource.apply(snapshot, animatingDifferences: animates)
            // a reconfigured row, or the old first row under new ones, may have a new height: the flow layout asks again.
            if !changed.isEmpty || prepended { collectionView.collectionViewLayout.invalidateLayout() }
            collectionView.layoutIfNeeded()
            anchorToBottom()
            // the one place this update leaves the list, unanimated.
            place(scroll)
        }
        updateJumpToUnread()
        if isAtBottom { model.didReadLatest() }
    }

    /// After the chat's scroll (`-LuxBenchmark`): a jump far back while its pages load, then new
    /// messages at the newest.
    private func runThreadBenchmark() {
        guard let room = model.rooms.first?.id else { return }
        tasks.run { [weak self] in
            guard let self else { return }
            try await ThreadBenchmark().run(
                jump: { presenter.jump(toMessage: MessageLink(roomId: room, eventId: "\(room)/1000")) },
                back: {
                    presenter.userStartedScrolling()
                    if !presenter.returnToLive() { scrollToBottom(animated: false) }
                },
                send: { model.send($0) })
        }
    }

    /// The list moves to where `intent` puts the rows `ids` before they go in unanimated (their
    /// heights are exact): the layout then makes cells only for the rows that will be on screen
    /// there, not for those where the list was (a jump's rows replacing the live ones, a page
    /// going in above the reader). `place(_:)` puts it exactly once they are in.
    private func preplace(_ intent: ScrollIntent, among ids: [String]) {
        let items = collectionView.numberOfSections > 0 ? collectionView.numberOfItems(inSection: 0) : 0
        let layout = collectionView.collectionViewLayout
        guard !intent.isAnimated, items > 0,
              let first = layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))?.frame,
              let last = layout.layoutAttributesForItem(at: IndexPath(item: items - 1, section: 0))?.frame else { return }
        // the section's own margins, as the layout has them now.
        let lead = first.minY, trail = layout.collectionViewContentSize.height - last.maxY
        guard let y = scrollGeometry.offset(for: intent, stacking: ids, height: { layouts[$0]?.height ?? 44 }, lead: lead, trail: trail),
              abs(y - collectionView.contentOffset.y) > 0.5 else { return }
        collectionView.contentOffset.y = y
    }

    /// An empty chat says so, once the server has had its say.
    private func updateEmpty() {
        empty.isHidden = !(model.hasLoaded && !model.isLoading && order.isEmpty)
    }

    func collectionView(_ collectionView: UICollectionView, layout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        // `order` mirrors the applied snapshot: an array index, not a data source lookup, for every row.
        let height = order.indices.contains(indexPath.item) ? layouts[order[indexPath.item]]?.height ?? 44 : 44
        return CGSize(width: presenter.width, height: height)
    }

    /// Photos and senders' pictures a few rows ahead start loading before their rows appear.
    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        guard let images = session.images else { return }
        let items = indexPaths.compactMap { dataSource.itemIdentifier(for: $0).flatMap { messages[$0] } }
        let scale = traitCollection.displayScale, metrics = presenter.layoutCache.metrics
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

    /// A Matrix thread of this chat, pushed over it (at one of its messages, if given).
    func openThread(_ thread: MatrixThread, at message: MessageLink? = nil) {
        let opened = ThreadViewController(session: session, row: row, theme: theme, list: list, focus: message, thread: thread)
        navigationController?.pushViewController(opened, animated: true)
    }

    var readingRow: String? {
        // the layout's rows in the list's bounds, whether or not their cells are made yet.
        let top = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        return (collectionView.collectionViewLayout.layoutAttributesForElements(in: collectionView.bounds) ?? [])
            .filter { $0.representedElementCategory == .cell && $0.frame.midY >= top }
            .min { $0.indexPath.item < $1.indexPath.item }
            .flatMap { order.indices.contains($0.indexPath.item) ? order[$0.indexPath.item] : nil }
    }

    /// The chat's details, from its title, as Messages opens a conversation's.
    @objc private func openDetails() {
        let details = ChatDetailsViewController(session: session, row: row, list: list)
        details.onChange = { [weak self] row in
            self?.chatTitle.show(row, images: self?.session.images)
            if self?.model.thread != nil { self?.chatTitle.subtitle = String(localized: "Thread") }
        }
        details.onOpenThread = { [weak self] thread in self?.openThread(thread) }
        details.pins = model
        details.onJump = { [weak self] pin in
            guard let self else { return }
            navigationController?.popToViewController(self, animated: true)
            presenter.jump(toMessage: pin.link)
        }
        shownDetails = details
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
        if presenter.shownFirst, let id = model.firstUnreadId, let span = rowSpan(of: id) {
            showUp = scrollGeometry.isAbove(span.maxY)
        }
        if showUp != (jumpToUnread.alpha == 1) {
            UIView.animate(withDuration: 0.2) { self.jumpToUnread.alpha = showUp ? 1 : 0 }
        }
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        // slid to the newest message: it is read.
        if isAtBottom { model.didReadLatest() }
        // UIKit also ends an animation another scroll replaced, where it stopped: only the
        // presenter's last glide, arrived, is its end.
        guard let end = glideEnd, abs(scrollView.contentOffset.y - end) < 1 else { return }
        glideEnd = nil
        presenter.didEndScrolling()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // a screen or more above the newest message: offer the way back.
        let geometry = scrollGeometry
        // a jump's rows are not the newest: the way back always shows.
        let showJump = presenter.shownFirst && (geometry.isScreenAboveBottom || !model.isLive)
        if showJump != (jumpToBottom.alpha == 1) {
            UIView.animate(withDuration: 0.2) { self.jumpToBottom.alpha = showJump ? 1 : 0 }
        }
        updateJumpToUnread()
    }

    /// A row comes on screen: near the top, older messages are asked for (near a jump's end, newer ones).
    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        presenter.displayed(scrollGeometry)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        presenter.userStartedScrolling()
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

extension ThreadViewController: ThreadScreen {
    func showDraft(_ text: String) { composer.text = text }

    var scrollGeometry: ScrollGeometry {
        let inset = collectionView.adjustedContentInset
        return ScrollGeometry(offset: collectionView.contentOffset.y, height: collectionView.bounds.height,
                              contentHeight: collectionView.contentSize.height, top: inset.top, bottom: inset.bottom)
    }

    func rowSpan(of id: String) -> (minY: CGFloat, maxY: CGFloat)? {
        guard let index = order.firstIndex(of: id),
              let frame = collectionView.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame else { return nil }
        return (frame.minY, frame.maxY)
    }

    func scrollList(to offset: CGFloat, animated: Bool) {
        glideEnd = animated ? offset : nil
        collectionView.setContentOffset(CGPoint(x: collectionView.contentOffset.x, y: offset), animated: animated)
        if !animated { collectionView.layoutIfNeeded() }
    }

    func highlight(_ id: String?) {
        let previous = highlighted
        highlighted = id
        // visible cells read it again; one shown later reads it as it is configured.
        for changed in [previous, id].compactMap(\.self) {
            guard let path = dataSource.indexPath(for: changed) else { continue }
            collectionView.cellForItem(at: path)?.setNeedsUpdateConfiguration()
        }
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
