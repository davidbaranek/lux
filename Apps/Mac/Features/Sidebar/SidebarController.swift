import AppKit
import LuxCore

/// The window's sidebar: the rail, and beside it a search field over the chat list (or, while
/// searching, what the search found, or one kind of it all: "Show All"). It owns the list's and
/// the search's models and wires them to the views.
final class SidebarController: NSViewController, NSSearchFieldDelegate {
    /// A chat to show (nil: none), and a message in it to scroll to.
    var onOpen: ((ChatRow?, _ focusEvent: String?) -> Void)?
    /// A thread to show beside its chat.
    var onOpenThread: ((ChatRow, MatrixThread) -> Void)?
    var onAccount: (() -> Void)?

    private let session: Session
    /// The shown place's colour changed: the open chat takes it too.
    var onTheme: ((PlaceTheme) -> Void)?
    /// The current place's name changed (another place, or the places came): the window shows it.
    var onPlaceTitle: ((String) -> Void)?
    /// The inbox's unread chats changed: the Dock's badge.
    var onBadge: ((Int) -> Void)?
    var placeTitle: String { listModel.places.first { $0.id == listModel.place }?.title ?? String(localized: "Inbox") }

    /// The list's model: the window's toolbar filters it.
    let listModel: ChatListModel
    private let searchModel: SearchModel
    private let rail: RailController
    private let list: ChatListController
    private let results: SearchResultsController
    /// One kind's list, while it shows in place of the results.
    private var listing: SearchListController?
    private let search = FocusSearchField()
    private let content = NSView()
    /// The shown place's colour over the whole sidebar.
    private let tint = ThemeTint(strength: ThemeTint.sidebar)

    init(session: Session) {
        self.session = session
        listModel = ChatListModel(session: session)
        searchModel = SearchModel(session: session)
        rail = RailController(images: session.images)
        list = ChatListController(session: session, model: listModel)
        results = SearchResultsController(images: session.images)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let container = NSView()
        for child in [rail, list, results] as [NSViewController] { addChild(child) }
        search.placeholderString = String(localized: "Search")
        // a taller field, as the sidebars of Messages and Mail have.
        search.controlSize = .large
        search.font = .systemFont(ofSize: NSFont.systemFontSize(for: .large))
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.target = self
        search.action = #selector(searchChanged)
        // the field took the focus: what chats shared lately shows before any words.
        search.onFocus = { [weak self] in self?.startSearching() }
        for view in [tint, rail.view, search, content] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            tint.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tint.topAnchor.constraint(equalTo: container.topAnchor),
            tint.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            rail.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            rail.view.topAnchor.constraint(equalTo: container.topAnchor),
            rail.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            search.leadingAnchor.constraint(equalTo: rail.view.trailingAnchor, constant: 10),
            search.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            search.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 6),
            content.leadingAnchor.constraint(equalTo: rail.view.trailingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 6),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
        show(list.view)

        rail.onSelect = { [weak self] place in
            guard let self else { return }
            listModel.place = place
            rail.select(place)
            onPlaceTitle?(placeTitle)
            updateTheme()
        }
        list.onActivity = { [weak self] action in
            guard let self else { return }
            switch action {
            case .show(let place):
                rail.onSelect?(place)
            case .signIn(let offer):
                guard let networks = session.networks, let window = view.window else { return }
                NetworkSignInController.present(networks.signIn(to: offer), over: window) {}
            }
        }
        rail.onAccount = { [weak self] in self?.onAccount?() }
        rail.onHide = { [weak self] place, hidden in
            guard let self else { return }
            if let place { listModel.setHidden(place, hidden) } else { listModel.showAllPlaces() }
        }
        rail.onTheme = { [weak self] place, theme in self?.listModel.setTheme(place, theme) }
        rail.onInbox = { [weak self] place, rule in self?.listModel.setInbox(place, rule) }
        rail.onNotifications = { [weak self] place, setting in self?.listModel.setNotifications(place, setting) }
        listModel.onPlaces = { [weak self] places in
            guard let self else { return }
            if let inbox = places.first(where: { $0.id == .inbox }) { onBadge?(inbox.unread) }
            rail.defaultTheme = listModel.defaultTheme
            rail.show(places, selected: listModel.place)
            onPlaceTitle?(placeTitle)
            updateTheme()
        }
        list.onSelect = { [weak self] row, focusEvent in self?.onOpen?(row, focusEvent) }
        results.onOpen = { [weak self] target in self?.open(target) }
        results.onShowAll = { [weak self] kind in self?.showAll(kind) }
        searchModel.onUpdate = { [weak self] hits in self?.results.show(hits) }
        // the index's progress under the results; the index opens a moment after the account.
        searchOpened = session.searchChanges.observe { [weak self] in self?.followIndex() }
        followIndex()
        // the account's picture, as Settings changes it.
        profileChanges = session.profile?.changes.observe { [weak self] in
            guard let self else { return }
            rail.showAccount(session.profile?.profile)
        }
        Task { await session.profile?.load() }
    }

    /// The shown place's colour: over the whole sidebar, and the list's accent. Neutral keeps the
    /// sidebar's material and the system's accent.
    private func updateTheme() {
        let theme = listModel.theme
        tint.theme = theme
        list.accent = theme.color ?? .controlAccentColor
        onTheme?(theme)
    }

    /// Cmd-F: the search field.
    @objc func performFindPanelAction(_ sender: Any?) {
        view.window?.makeFirstResponder(search)
    }

    /// What the keyboard starts at when the window opens: the chats.
    var initialFocus: NSView { list.initialFocus }

    private func startSearching() {
        searchModel.prepare()
        if listing == nil { show(results.view) }
    }

    @objc private func searchChanged() {
        if let listing {
            listing.search(search.stringValue)
            return
        }
        searchModel.search(search.stringValue)
        show(results.view)
    }

    /// The field was cleared: back to the chats, unless a kind's list shows (it lists all).
    func searchFieldDidEndSearching(_ sender: NSSearchField) {
        guard listing == nil else { return }
        show(list.view)
    }

    /// The field lost the focus with nothing in it: back to the chats.
    func controlTextDidEndEditing(_ notification: Notification) {
        guard search.stringValue.isEmpty, listing == nil else { return }
        show(list.view)
    }

    /// A result: its chat (at its message), its thread beside its chat, or a link's page.
    private func open(_ target: SearchTarget) {
        switch target {
        case .chat(let row, let focusEvent): onOpen?(row, focusEvent)
        case .thread(let row, let thread): onOpenThread?(row, thread)
        case .link(let url): NSWorkspace.shared.open(url)
        }
    }

    /// One kind, all of it, in place of the results: the field searches it, with the words it has.
    private func showAll(_ kind: SearchKind) {
        let controller = SearchListController(model: searchModel.list(kind), images: session.images)
        controller.onOpen = { [weak self] target in self?.open(target) }
        controller.onBack = { [weak self] in self?.closeList() }
        listing?.removeFromParent()
        listing = controller
        addChild(controller)
        search.placeholderString = String(localized: "Search \(kind.title)")
        show(controller.view, .push)
    }

    /// Back to the results, for the words in the field now.
    private func closeList() {
        guard let listing else { return }
        listing.removeFromParent()
        self.listing = nil
        search.placeholderString = String(localized: "Search")
        searchModel.search(search.stringValue)
        show(results.view, .pop)
        view.window?.makeFirstResponder(search)
    }

    private var searchOpened: AnyObject?
    private var profileChanges: AnyObject?
    private var indexProgress: AnyObject?

    private func followIndex() {
        indexProgress = session.search?.progressChanges.observe { [weak self] in
            self?.results.showProgress(self?.session.search?.progress)
        }
        results.showProgress(session.search?.progress)
    }

    /// How the sidebar's content changes: the list and search cross-fade; a kind's list slides
    /// in from the side, and back out.
    private enum Change { case fade, push, pop }

    private func show(_ child: NSView, _ change: Change = .fade) {
        guard child.superview != content else { return }
        if content.window != nil {
            let transition = CATransition()
            transition.duration = change == .fade ? 0.16 : 0.24
            transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            switch change {
            case .fade: transition.type = .fade
            case .push: transition.type = .push; transition.subtype = .fromRight
            case .pop: transition.type = .push; transition.subtype = .fromLeft
            }
            content.wantsLayer = true
            content.layer?.add(transition, forKey: "content")
        }
        content.subviews.forEach { $0.removeFromSuperview() }
        child.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            child.topAnchor.constraint(equalTo: content.topAnchor),
            child.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }
}

/// The sidebar's search field, which says when it takes the focus: search shows before any words.
final class FocusSearchField: NSSearchField {
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocus?() }
        return became
    }
}
