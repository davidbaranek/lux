import AppKit
import LuxCore

/// The window's sidebar: the rail, and beside it a search field over the chat list (or, while
/// searching, what the search found). It owns the list's and the search's models and wires them
/// to the views.
final class SidebarController: NSViewController, NSSearchFieldDelegate {
    /// A chat to show (nil: none), and a message in it to scroll to.
    var onOpen: ((ChatRow?, _ focusEvent: String?) -> Void)?
    var onAccount: (() -> Void)?

    private let session: Session
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
    private let search = NSSearchField()
    private let content = NSView()

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
        for view in [rail.view, search, content] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
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
        listModel.onPlaces = { [weak self] places in
            guard let self else { return }
            if let inbox = places.first(where: { $0.id == .inbox }) { onBadge?(inbox.unread) }
            rail.show(places, selected: listModel.place)
            onPlaceTitle?(placeTitle)
        }
        list.onSelect = { [weak self] row, focusEvent in self?.onOpen?(row, focusEvent) }
        results.onOpen = { [weak self] row, focusEvent in self?.onOpen?(row, focusEvent) }
        searchModel.onUpdate = { [weak self] hits in self?.results.show(hits) }
        // the index's progress under the results; the index opens a moment after the account.
        searchOpened = session.searchChanges.observe { [weak self] in self?.followIndex() }
        followIndex()
        Task {
            let settings = SettingsModel(session: session)
            await settings.load()
            rail.showAccount(settings.profile)
        }
    }

    /// Cmd-F: the search field.
    @objc func performFindPanelAction(_ sender: Any?) {
        view.window?.makeFirstResponder(search)
    }

    @objc private func searchChanged() {
        searchModel.search(search.stringValue)
        show(search.stringValue.isEmpty ? list.view : results.view)
    }

    func searchFieldDidEndSearching(_ sender: NSSearchField) {
        show(list.view)
    }

    private var searchOpened: AnyObject?
    private var indexProgress: AnyObject?

    private func followIndex() {
        indexProgress = session.search?.progressChanges.observe { [weak self] in
            self?.results.showProgress(self?.session.search?.progress)
        }
        results.showProgress(session.search?.progress)
    }

    private func show(_ child: NSView) {
        guard child.superview != content else { return }
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
