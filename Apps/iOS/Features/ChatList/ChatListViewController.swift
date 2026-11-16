import LuxCore
import UIKit

/// The chats of one place, newest message first: a list layout over a diffable data source keyed
/// by room id. A row renders again only when what it shows changed (`reconfigureItems`). The search
/// field searches as Messages does. The bottom toolbar holds the filter (unread, drafts, groups…),
/// the places (the Mac's rail: the inbox, the archive and the current place, every place behind the
/// chevron) and the search.
final class ChatListViewController: UIViewController, UICollectionViewDelegate, UICollectionViewDataSourcePrefetching,
    UISearchResultsUpdating, ChatListScreen {
    let session: Session
    /// The list's logic, shared with the Mac: updates, the activity bubble.
    private let presenter: ChatListPresenter
    var model: ChatListModel { presenter.model }
    /// The list's own work (a new chat, the welcome, notifications' chats): it ends with the list.
    let tasks = TaskBag()
    private let signOut: () -> Void
    private lazy var searchModel = SearchModel(session: session)
    /// Search's own navigation: the results, and a kind's list over them.
    private let resultsNavigation = UINavigationController()
    private var rows: [String: ChatRow] = [:]
    /// The first sync's progress, over the top of the list.
    private let loading = LoadingBubble(text: String(localized: "Loading chats…"))
    private var indexProgress: AnyObject?
    private var searchOpened: AnyObject?
    private var collectionView: UICollectionView!
    private var titles: [String: String] = [:]
    /// What a grid item's id starts with (the chat's id follows).
    private static let gridPrefix = "grid:"
    /// The sections drawn as a grid (the inbox's pinned chats).
    private var gridSections: Set<String> = []
    private var dataSource: UICollectionViewDiffableDataSource<String, String>!
    /// The shown place's colour behind the top of the list.
    private let band = ThemeBand()

    /// The app's badge: the inbox's unread chats.
    private let badge: (Int) -> Void

    init(session: Session, badge: @escaping (Int) -> Void = { _ in }, signOut: @escaping () -> Void) {
        self.session = session
        self.badge = badge
        self.signOut = signOut
        presenter = ChatListPresenter(session: session, model: ChatListModel(session: session))
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Chats")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .always
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .compose, primaryAction: UIAction { [weak self] _ in self?.newConversation() })
        navigationItem.leftBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "gearshape"), primaryAction: UIAction { [weak self] _ in
            self?.openSettings()
        })
        navigationItem.leftBarButtonItem?.accessibilityLabel = String(localized: "Settings")

        let results = SearchResultsViewController(images: session.images, open: { [weak self] target in
            self?.open(target)
        }, showAll: { [weak self] kind in
            self?.showAll(kind)
        })
        // a kind's list ("Show All") is pushed within search, which the field then searches.
        resultsNavigation.setViewControllers([results], animated: false)
        results.onAppear = { [weak self] in
            guard let self, let field = navigationItem.searchController?.searchBar else { return }
            field.placeholder = String(localized: "Search")
            searchModel.search(field.text ?? "")
        }
        let search = UISearchController(searchResultsController: resultsNavigation)
        search.searchResultsUpdater = self
        search.searchBar.placeholder = String(localized: "Search")
        navigationItem.searchController = search
        // the search sits in the bottom toolbar, beside the places (`updatePlaces`).
        navigationItem.preferredSearchBarPlacement = .integratedButton
        searchModel.onUpdate = { hits in results.show(hits) }
        results.showProgress(session.search?.progress)
        // the index opens a moment after the account: follow its progress once it has.
        searchOpened = session.searchChanges.observe { [weak self, weak results] in
            guard let self, let search = session.search else { return }
            results?.showProgress(search.progress)
            indexProgress = search.progressChanges.observe { [weak results, weak search] in results?.showProgress(search?.progress) }
        }
        if let search = session.search {
            indexProgress = search.progressChanges.observe { [weak results, weak search] in results?.showProgress(search?.progress) }
        }

        // a space's own spaces head their chats (Discord's categories); other sections have no header.
        let layout = UICollectionViewCompositionalLayout { [weak self] index, environment in
            if let id = self?.dataSource.sectionIdentifier(for: index), self?.gridSections.contains(id) == true {
                return Self.pinnedGrid(environment)
            }
            var list = UICollectionLayoutListConfiguration(appearance: .plain)
            // clear: the place's colour shows through at the top (`ThemeBand`).
            list.backgroundColor = .clear
            // no line above a section's first chat: lines only between chats.
            list.itemSeparatorHandler = { indexPath, configuration in
                var configuration = configuration
                if indexPath.item == 0 { configuration.topSeparatorVisibility = .hidden }
                return configuration
            }
            // swipe right: read / unread, as Mail and Messages do.
            list.leadingSwipeActionsConfigurationProvider = { [weak self] indexPath in
                guard let self, let id = dataSource.itemIdentifier(for: indexPath), let row = rows[id] else { return nil }
                let action = UIContextualAction(style: .normal, title: nil) { [weak self] _, _, done in
                    self?.model.setUnread(row.id, !row.isUnread)
                    done(true)
                }
                action.image = UIImage(systemName: row.isUnread ? "envelope.open.fill" : "envelope.badge.fill")
                action.backgroundColor = .systemBlue
                return UISwipeActionsConfiguration(actions: [action])
            }
            // swipe left: Low Priority (or back to the inbox), as Mail moves a message.
            list.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
                guard let self, let id = dataSource.itemIdentifier(for: indexPath), let row = rows[id] else { return nil }
                let low = row.folder == .lowPriority
                let action = UIContextualAction(style: .normal, title: low ? String(localized: "Inbox") : String(localized: "Low Priority")) {
                    [weak self] _, _, done in
                    self?.model.change(row.id, low ? .inbox : .lowPriority)
                    done(true)
                }
                action.image = UIImage(systemName: low ? "tray.and.arrow.up.fill" : "arrow.down.circle.fill")
                action.backgroundColor = .systemIndigo
                return UISwipeActionsConfiguration(actions: [action])
            }
            let section = self?.dataSource.sectionIdentifier(for: index)
            list.headerMode = section.flatMap { self?.titles[$0] } == nil ? .none : .supplementary
            return .list(using: list, layoutEnvironment: environment)
        }
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        collectionView.accessibilityIdentifier = "chats"
        // the action's sender is not the control here: end the control the list owns.
        collectionView.refreshControl = UIRefreshControl(frame: .zero, primaryAction: UIAction { [weak self] _ in
            self?.model.reload()
            self?.collectionView.refreshControl?.endRefreshing()
        })
        collectionView.backgroundColor = .systemBackground
        collectionView.addSubview(band)
        view.addSubview(collectionView)
        // what scrolls under the bar blurs out gradually, not at a hard edge (the system's default).
        collectionView.topEdgeEffect.style = .soft

        let images = session.images
        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, _, id in
            guard let row = self?.rows[id] else { return }
            cell.contentConfiguration = ChatRowConfiguration(row: row, images: images)
            cell.accessories = []
            // at rest the row is clear, so the place's colour shows behind it (`ThemeBand`); a
            // touch or a selection fills it as the system's list does.
            cell.configurationUpdateHandler = { cell, state in
                var background = UIBackgroundConfiguration.listCell().updated(for: state)
                if !state.isHighlighted && !state.isSelected { background.backgroundColor = .clear }
                cell.backgroundConfiguration = background
            }
        }
        let pinned = UICollectionView.CellRegistration<PinnedChatCell, String> { [weak self] cell, _, id in
            guard let row = self?.rows[id] else { return }
            cell.show(row, images: images)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { [weak self] collectionView, indexPath, id in
            let grid = self?.dataSource.sectionIdentifier(for: indexPath.section).map { self?.gridSections.contains($0) == true } ?? false
            return grid ? collectionView.dequeueConfiguredReusableCell(using: pinned, for: indexPath, item: id)
                        : collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: id)
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) {
            [weak self] header, _, indexPath in
            var content = UIListContentConfiguration.header()
            content.text = self?.dataSource.sectionIdentifier(for: indexPath.section).flatMap { self?.titles[$0] }
            header.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }

        // the bubble sits in the top bar, between Settings and New Message: nothing in the list moves.
        navigationItem.titleView = loading
        model.onPlaces = { [weak self] places in
            if let inbox = places.first(where: { $0.id == .inbox }) { self?.badge(inbox.unread) }
            self?.updatePlaces()
            self?.placesSheet?.show(places)
        }
        model.onError = { [weak self] error in self?.report(error, of: "chat list") }
        presenter.screen = self
        presenter.start()
        tasks.run { [weak self] in
            // encryption first: the networks' welcome waits until this device can read.
            await self?.offerEncryptionSetup()
            await self?.welcomeToNetworks()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(false, animated: animated)
        updateTheme()
        // a draft may have been written or sent in the chat just left.
        if model.filter == .drafts { model.refresh() }
        guard let selected = collectionView.indexPathsForSelectedItems?.first else { return }
        if let coordinator = transitionCoordinator {
            coordinator.animate { _ in self.collectionView.deselectItem(at: selected, animated: true) } completion: { context in
                if context.isCancelled { self.collectionView.selectItem(at: selected, animated: false, scrollPosition: []) }
            }
        } else {
            collectionView.deselectItem(at: selected, animated: animated)
        }
    }

    /// The bubble says what the app is doing (connecting, updating chats, preparing search) and how
    /// far it is.
    func showActivity(_ activity: ListActivity?, toggles: Bool) {
        if let activity {
            loading.text = activity.title
            loading.detail = activity.detail
            loading.isWarning = activity.isWarning
            loading.onTap = activity.action.map { action in { [weak self] in self?.perform(action) } }
        }
        if toggles { loading.set(visible: activity != nil) }
    }

    /// The bubble's tap: a network's chats while its history arrives, a sign-in for one signed out.
    private func perform(_ action: ListActivity.Action) {
        switch action {
        case .show(let place):
            go(to: place)
        case .signIn(let offer):
            guard let networks = session.networks else { return }
            present(NetworkSignInViewController(signIn: networks.signIn(to: offer)) {}, animated: true)
        }
    }

    /// After signing in: what this device needs to read encrypted messages. An unverified device
    /// is asked to verify at each launch; an account without recovery is offered it once. Returns
    /// when the sheet is gone (or none was needed).
    private func offerEncryptionSetup() async {
        guard let security = session.security else { return }
        let setup = await security.knownSetup()
        guard presentedViewController == nil else { return }
        let sheet: UIViewController
        switch setup {
        case .verifyThisDevice(let withRecoveryKey):
            sheet = ConfirmIdentityViewController(session: session, withRecoveryKey: withRecoveryKey)
        case .setUpRecovery where !Preferences.shared.recoverySetupOffered || LaunchOptions.demoNoRecovery:
            if !LaunchOptions.isDemo { Preferences.shared.recoverySetupOffered = true }
            sheet = RecoverySetupViewController(security: security)
        case .setUpRecovery, .ready, .unknown:
            return
        }
        await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
            present(SheetNavigationController(root: sheet) { finished.resume() }, animated: true)
        }
    }

    /// After signing in, once: the server's networks, to pick the ones to bring.
    private func welcomeToNetworks() async {
        guard let networks = session.networks else { return }
        // the bubble tells of a network signed out, too.
        await networks.load()
        let welcomed = Preferences.shared.networksWelcomed && !LaunchOptions.showsNetworksWelcome
        guard !welcomed, !LaunchOptions.isDemo || LaunchOptions.showsNetworksWelcome, presentedViewController == nil else { return }
        // the demo never marks the account's welcome as shown.
        if !LaunchOptions.isDemo { Preferences.shared.networksWelcomed = true }
        // a server with networks the account already has, or none at all after a restore: nothing to welcome to.
        guard !networks.offered.isEmpty, networks.hasNoLogins else { return }
        let welcome = UINavigationController(rootViewController: NetworksViewController(model: networks, mode: .welcome))
        welcome.navigationBar.prefersLargeTitles = true
        present(welcome, animated: true)
    }

    func show(_ update: ChatListUpdate) {
        let sections = update.sections, first = update.isFirst
        // a grid item has its own id: a chat moving into the grid or out of it is a new item with
        // the other kind of cell, not the old cell configured again.
        func itemId(_ row: ChatRow, in section: ChatSection) -> String { section.style == .grid ? Self.gridPrefix + row.id : row.id }
        rows = Dictionary(sections.flatMap { section in section.rows.map { (itemId($0, in: section), $0) } },
                          uniquingKeysWith: { first, _ in first })
        titles = update.titles
        gridSections = update.gridSections
        var snapshot = NSDiffableDataSourceSnapshot<String, String>()
        for section in sections {
            snapshot.appendSections([section.id])
            snapshot.appendItems(section.rows.map { itemId($0, in: section) }, toSection: section.id)
        }
        let changed = update.changed.flatMap { [$0, Self.gridPrefix + $0] }.filter { snapshot.indexOfItem($0) != nil }
        let state = Signposts.list.beginInterval("apply")
        if first {
            dataSource.applySnapshotUsingReloadData(snapshot)
        } else {
            snapshot.reconfigureItems(changed)
            if !update.isNewPlace || view.window == nil {
                dataSource.apply(snapshot, animatingDifferences: view.window != nil)
            } else {
                // another place: its chats cross-fade in, quickly, in place of the last one's.
                UIView.transition(with: collectionView, duration: 0.18, options: [.transitionCrossDissolve, .allowUserInteraction]) {
                    self.dataSource.applySnapshotUsingReloadData(snapshot)
                }
            }
        }
        Signposts.list.endInterval("apply", state, "\(changed.count) changed")
    }

    /// `-LuxBenchmark`: scroll the list down and back, then open a chat (which scrolls itself).
    func runBenchmark(_ rows: [ChatRow]) {
        ScrollBenchmark(collectionView, name: "chat list", direction: 1).run { [weak self] in
            guard let self, let row = rows.first(where: \.isGroup) else { return }
            navigationController?.pushViewController(ThreadViewController(session: session, row: row, theme: model.theme, list: model), animated: false)
        }
    }

    /// Avatars a few rows ahead start loading before their rows appear.
    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        let refs = indexPaths.compactMap { dataSource.itemIdentifier(for: $0).flatMap { rows[$0]?.avatar } }
        session.images?.prefetch(refs, pixels: AvatarView.pixels(52, traitCollection), shape: .circle)
    }

    /// Long press on a chat: mark it read or unread.
    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard let id = indexPaths.first.flatMap({ dataSource.itemIdentifier(for: $0) }), let row = rows[id] else { return nil }
        switch model.destination(of: row) {
        case .chat:
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in self?.menu(for: row) }
        case .message:
            guard let saved = model.saved(of: row) else { return nil }
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                UIMenu(children: [UIAction(title: MessageAction.unsave.title, image: UIImage(systemName: MessageAction.unsave.symbol),
                                           attributes: .destructive) { _ in self?.model.unsave(saved) }])
            }
        case .scheduled(let waiting):
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                UIMenu(children: [UIAction(title: String(localized: "Don't Send"), image: UIImage(systemName: "xmark.circle"),
                                           attributes: .destructive) { _ in self?.model.cancel(waiting) }])
            }
        case .request:
            return nil
        }
    }

    /// What `ChatChange` offers for the chat, with its labels in a submenu.
    private func menu(for row: ChatRow) -> UIMenu {
        let changes = ChatChange.available(for: row)
        func action(_ change: ChatChange) -> UIAction {
            UIAction(title: change.title, image: UIImage(systemName: change.symbol), attributes: change.isDestructive ? .destructive : []) {
                [weak self] _ in self?.perform(change, on: row)
            }
        }
        let main = changes.filter { !$0.isDestructive }.map(action)
        return UIMenu(children: [UIMenu(options: .displayInline, children: main), remindMenu(for: row), labelsMenu(for: row), notificationsMenu(for: row),
                                 mergeMenu(for: row), UIMenu(options: .displayInline, children: changes.filter(\.isDestructive).map(action))])
    }

    /// When the chat's messages notify, as its details say.
    private func notificationsMenu(for row: ChatRow) -> UIMenu {
        NotificationMenu.menu(current: row.notifications) { [weak self] setting in
            self?.model.setNotifications(row.id, setting)
        }
    }

    /// One person's chats on several networks as one: merge with another chat, or take a merged
    /// chat apart. Not for groups.
    private func mergeMenu(for row: ChatRow) -> UIMenu {
        guard !row.isGroup else { return UIMenu(options: .displayInline, children: []) }
        var items: [UIMenuElement] = [
            UIAction(title: String(localized: "Merge With…"), image: UIImage(systemName: "arrow.triangle.merge")) { [weak self] _ in
                guard let self else { return }
                let picker = ChatPickerViewController(session: session, title: String(localized: "Merge With")) { [weak self] other in
                    self?.model.merge(row, with: other)
                }
                present(UINavigationController(rootViewController: picker), animated: true)
            },
        ]
        if row.isMerged {
            items.append(UIAction(title: String(localized: "Separate Chats"), image: UIImage(systemName: "arrow.triangle.branch")) {
                [weak self] _ in self?.model.unmerge(row)
            })
        }
        return UIMenu(options: .displayInline, children: items)
    }

    /// Remind me to answer: soon, this evening, tomorrow, next week; or stop.
    private func remindMenu(for row: ChatRow) -> UIMenu {
        var items: [UIMenuElement] = LaterTime.offered().map { time in
            let date = time.date()
            return UIAction(title: time.title, subtitle: TimeText.upcoming(date), image: UIImage(systemName: time.symbol)) { [weak self] _ in
                self?.model.setReminder(row.id, at: date)
            }
        }
        if row.reminder != nil {
            items.append(UIMenu(options: .displayInline, children: [
                UIAction(title: String(localized: "Remove Reminder"), image: UIImage(systemName: "bell.slash"), attributes: .destructive) {
                    [weak self] _ in self?.model.setReminder(row.id, at: nil)
                },
            ]))
        }
        let title = row.reminder.map { String(localized: "Remind Me · \(TimeText.upcoming($0))") } ?? String(localized: "Remind Me")
        return UIMenu(title: title, image: UIImage(systemName: "bell"), children: items)
    }

    /// The labels, the chat's ticked; a tap puts it in or takes it out. New Label makes one.
    private func labelsMenu(for row: ChatRow) -> UIMenu {
        let labels = model.labels.map { label in
            UIAction(title: label.name, image: UIImage(systemName: "tag"), state: label.rooms.contains(row.id) ? .on : .off) { [weak self] _ in
                self?.model.setChat(row.id, inLabel: label.id, !label.rooms.contains(row.id))
            }
        }
        let new = UIAction(title: String(localized: "New Label…"), image: UIImage(systemName: "plus")) { [weak self] _ in
            self?.askForLabel(for: row)
        }
        return UIMenu(title: String(localized: "Labels"), image: UIImage(systemName: "tag"), children: labels + [new])
    }

    private func askForLabel(for row: ChatRow) {
        let alert = UIAlertController(title: String(localized: "New Label"), message: nil, preferredStyle: .alert)
        alert.addTextField { $0.placeholder = String(localized: "Name") }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Create"), style: .default) { [weak self, weak alert] _ in
            guard let name = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return }
            self?.model.makeLabel(named: name, with: row.id)
        })
        present(alert, animated: true)
    }

    /// Does a menu's change; deleting asks first.
    private func perform(_ change: ChatChange, on row: ChatRow) {
        guard change.needsConfirmation else { return model.change(row.id, change) }
        let alert = UIAlertController(title: String(localized: "Delete \(row.name)?"), message: ChatChange.deleteWarning, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Delete"), style: .destructive) { [weak self] _ in
            self?.model.change(row.id, change)
        })
        present(alert, animated: true)
    }

    /// A waiting message: it can be cancelled.
    private func cancel(_ waiting: ScheduledMessage, from cell: UIView?) {
        let sheet = UIAlertController(title: String(localized: "Sends \(TimeText.upcoming(waiting.sendAt))"), message: waiting.body,
                                      preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: String(localized: "Don't Send"), style: .destructive) { [weak self] _ in self?.model.cancel(waiting) })
        sheet.addAction(UIAlertAction(title: String(localized: "Keep"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = cell
        present(sheet, animated: true)
    }

    /// A request: accept (and open the chat) or decline.
    private func answer(_ row: ChatRow, from cell: UIView?) {
        let sheet = UIAlertController(title: row.name, message: row.preview, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: String(localized: "Accept"), style: .default) { [weak self] _ in
            self?.model.answer(request: row.id, accept: true)
        })
        sheet.addAction(UIAlertAction(title: String(localized: "Decline"), style: .destructive) { [weak self] _ in
            self?.model.answer(request: row.id, accept: false)
        })
        sheet.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = cell
        present(sheet, animated: true)
    }

    /// Four pictures to a row, as Messages lays out its pinned conversations.
    private static func pinnedGrid(_ environment: any NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection {
        let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(0.25), heightDimension: .estimated(100)))
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(100)),
                                                       repeatingSubitem: item, count: 4)
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = 8
        section.contentInsetsReference = .layoutMargins
        section.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 0, bottom: 12, trailing: 0)
        return section
    }

    /// A finger is down on a chat: start opening it before the tap ends.
    func collectionView(_ collectionView: UICollectionView, didHighlightItemAt indexPath: IndexPath) {
        if let id = dataSource.itemIdentifier(for: indexPath), let row = rows[id] { model.prefetch(row.id) }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let id = dataSource.itemIdentifier(for: indexPath), let row = rows[id] else { return }
        let cell = collectionView.cellForItem(at: indexPath)
        switch model.destination(of: row) {
        case .chat(let chat): open(chat)
        case .message(let chat, let eventId): open(chat, focusEvent: eventId)
        case .scheduled(let waiting):
            collectionView.deselectItem(at: indexPath, animated: true)
            cancel(waiting, from: cell)
        case .request(let request):
            collectionView.deselectItem(at: indexPath, animated: true)
            answer(request, from: cell)
        }
    }

    /// A search result: its chat (at its message), its thread, or a link's page.
    private func open(_ target: SearchTarget) {
        switch target {
        case .chat(let row, let focusEvent): open(row, focusEvent: focusEvent)
        case .thread(let row, let thread): open(row, thread: thread)
        case .link(let url): UIApplication.shared.open(url)
        }
    }

    /// One kind of what chats shared, all of it, on its own page within search: the field
    /// searches it, starting with the words typed; back returns to the results.
    private func showAll(_ kind: SearchKind) {
        let list = SearchListViewController(model: searchModel.list(kind), images: session.images) { [weak self] target in
            self?.open(target)
        }
        resultsNavigation.pushViewController(list, animated: true)
        navigationItem.searchController?.searchBar.placeholder = String(localized: "Search \(kind.title)")
    }

    private func open(_ row: ChatRow, focusEvent: String? = nil, thread: MatrixThread? = nil) {
        let chat = ThreadViewController(session: session, row: row, theme: model.theme, list: model, focusEvent: focusEvent)
        navigationController?.pushViewController(chat, animated: thread == nil)
        // a thread over its chat: back goes to the chat.
        if let thread { chat.openThread(thread) }
    }

    /// Opens the chat of a notification the user tapped: the merged chat its room is part of,
    /// else the room's own, over whatever was on screen; a thread's reply, at the thread. Right
    /// after launch the account's chats may not have come yet: the list waits for them a few seconds.
    func openChat(roomId: String, thread: String? = nil) {
        guard session.isSignedIn else { return }
        // a newer notification's chat replaces one still waiting.
        tasks.run("notification") { [weak self, model] in
            guard let row = await model.chat(ofRoom: roomId), let self else { return }
            presentedViewController?.dismiss(animated: false)
            navigationController?.popToRootViewController(animated: false)
            open(row, thread: thread.map { MatrixThread(roomId: roomId, rootEventId: $0) })
        }
    }

    func updateSearchResults(for searchController: UISearchController) {
        // the field took the focus: photo search gets ready before the first letter.
        if searchController.isActive { searchModel.prepare() }
        // the results show from the field's first focus: what chats shared lately, before words.
        searchController.showsSearchResultsController = searchController.isActive
        // search closed: it opens on its results next time.
        if !searchController.isActive {
            searchModel.close()
            if resultsNavigation.viewControllers.count > 1 { resultsNavigation.popToRootViewController(animated: false) }
        }
        // while a kind's list shows, the field searches it.
        if let list = resultsNavigation.topViewController as? SearchListViewController {
            list.search(searchController.searchBar.text ?? "")
            return
        }
        searchModel.search(searchController.searchBar.text ?? "")
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    private func openSettings() {
        navigationController?.pushViewController(SettingsViewController(session: session, model: SettingsModel(session: session), list: model,
                                                                        signOut: signOut), animated: true)
    }

    // MARK: Places

    /// Every place, in a sheet from the bottom, at the end of the places.
    lazy var allPlacesButton: UIBarButtonItem = {
        let item = UIBarButtonItem(image: UIImage(systemName: "chevron.up.chevron.down"), primaryAction: UIAction { [weak self] _ in
            self?.showAllPlaces()
        })
        item.accessibilityLabel = String(localized: "All Places")
        return item
    }()
    weak var placesSheet: PlacesSheetViewController?

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        band.place(in: collectionView)
    }

    func scrollViewDidChangeAdjustedContentInset(_ scrollView: UIScrollView) {
        band.place(in: scrollView)
    }

    /// The shown place's colour: the accent of the list and of what opens from it, the band at the
    /// top, and the open chat's own bubbles. Neutral keeps the app's own.
    func updateTheme() {
        let theme = model.theme
        band.theme = theme
        navigationController?.view.tintColor = theme.color
        for case let thread as ThreadViewController in navigationController?.viewControllers ?? [] { thread.theme = theme }
    }

    /// Which of the place's chats show: the button at the bottom left.
    lazy var filterButton: UIBarButtonItem = {
        let menu = UIMenu(title: String(localized: "Filter"), children: [
            UIDeferredMenuElement.uncached { [weak self] completion in completion(self?.filterMenuElements() ?? []) },
        ])
        let item = UIBarButtonItem(image: UIImage(systemName: "line.3.horizontal.decrease"), menu: menu)
        item.accessibilityLabel = String(localized: "Filter")
        return item
    }()

    /// The shortcut buttons, by place, kept so an update changes a button rather than the toolbar.
    var shortcutItems: [Place: UIBarButtonItem] = [:]
    var shortcutOrder: [Place] = []

    /// A new conversation, as a full card over the list (as Messages composes one).
    private func newConversation() {
        let picker = NewConversationViewController(session: session, open: { [weak self] row in self?.open(row) },
                                                   newRoom: { [weak self] in self?.newChat() })
        let navigation = UINavigationController(rootViewController: picker)
        navigation.sheetPresentationController?.detents = [.large()]
        present(navigation, animated: true)
    }

    private func newChat() {
        let alert = UIAlertController(title: String(localized: "New Chat"), message: String(localized: "An encrypted room with only you in it."),
                                      preferredStyle: .alert)
        alert.addTextField { $0.placeholder = String(localized: "Name") }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Create"), style: .default) { [weak self, weak alert] _ in
            guard let self, let name = alert?.textFields?.first?.text, !name.isEmpty else { return }
            tasks.run { [weak self, model] in
                let id: String
                do { id = try await model.createRoom(name: name) } catch { self?.report(error, of: "new chat"); return }
                guard let self else { return }
                let row = ChatRow(id: id, name: name, preview: "", date: nil)
                navigationController?.pushViewController(ThreadViewController(session: session, row: row, theme: model.theme, list: model), animated: true)
            }
        })
        present(alert, animated: true)
    }
}

/// A sheet's navigation that tells when it is gone, closed by its own button or swiped away.
private final class SheetNavigationController: UINavigationController {
    private var gone: (() -> Void)?

    init(root: UIViewController, gone: @escaping () -> Void) {
        self.gone = gone
        super.init(rootViewController: root)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isBeingDismissed else { return }
        gone?()
        gone = nil
    }
}
