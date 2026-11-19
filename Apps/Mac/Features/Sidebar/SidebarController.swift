import AppKit
import LuxCore

/// The window's sidebar: the rail, and beside it a search field over the chat list (or, while
/// searching, what the search found, or one kind of it all: "Show All"). It owns the list's and
/// the search's models and wires them to the views.
///
/// What shows follows the field: words show what they found; no words show what chats shared
/// lately while the field or the results have the keyboard, and the chats once it goes
/// elsewhere. While search shows, a close button beside the field ends it, also with no words
/// (the field's own clear button shows only with words, and only clears them); so does Esc.
final class SidebarController: NSViewController, NSSearchFieldDelegate {
    /// A chat to show (nil: none), and a message in it to scroll to.
    var onOpen: ((ChatRow?, _ focus: MessageLink?) -> Void)?
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
    private let search = SidebarSearchField()
    /// The window's first responder, followed: search with no words ends as the keyboard leaves it.
    private var focusChanges: NSKeyValueObservation?
    /// Ends search, beside the field whenever search shows. AppKit's search field shows its own
    /// clear button only while it has words, so it cannot be search's exit.
    private lazy var closeSearch: NSButton = {
        let button = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: String(localized: "Close Search"))!,
                              target: self, action: #selector(closeSearchClicked))
        button.bezelStyle = .glass
        button.borderShape = .circle
        button.toolTip = String(localized: "Close Search")
        button.setAccessibilityIdentifier("close-search")
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()
    /// The close button is shown (or coming): its animation only presents this.
    private var isCloseSearchShown = false
    /// The field's end: short of the close button while search shows.
    private var searchTrailing: NSLayoutConstraint!
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
        // the field took the focus (a click, Cmd-F, Tab): what chats shared lately shows before
        // any words.
        search.onFocus = { [weak self] in self?.startSearching() }
        search.onWindow = { [weak self] window in self?.followFocus(in: window) }
        // the field's clear button keeps its own meaning: it empties the field, and search stays.
        closeSearch.alphaValue = 0
        closeSearch.isHidden = true
        searchTrailing = search.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10)
        for view in [tint, rail.view, search, closeSearch, content] {
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
            searchTrailing,
            search.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 6),
            // as tall as the field, round, at the sidebar's edge: it comes out of the field's end.
            closeSearch.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            closeSearch.centerYAnchor.constraint(equalTo: search.centerYAnchor),
            closeSearch.heightAnchor.constraint(equalTo: search.heightAnchor),
            closeSearch.widthAnchor.constraint(equalTo: closeSearch.heightAnchor),
            content.leadingAnchor.constraint(equalTo: rail.view.trailingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 6),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
        show(list.view)

        rail.onSelect = { [weak self] place in
            guard let self else { return }
            // another place: search ends, its chats show.
            if content.subviews.first !== list.view { endSearch() }
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
        listModel.onPlaces = { [weak self] places in self?.showPlaces(places) }
        // the places that came before the view loaded.
        if !listModel.places.isEmpty { showPlaces(listModel.places) }
        list.onSelect = { [weak self] row, focus in self?.onOpen?(row, focus) }
        results.onOpen = { [weak self] target in self?.open(target) }
        results.onShowAll = { [weak self] kind in self?.showAll(kind) }
        results.onCancel = { [weak self] in self?.endSearch() }
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

    private func showPlaces(_ places: [PlaceItem]) {
        if let inbox = places.first(where: { $0.id == .inbox }) { onBadge?(inbox.unread) }
        rail.defaultTheme = listModel.defaultTheme
        rail.show(places, selected: listModel.place)
        onPlaceTitle?(placeTitle)
        updateTheme()
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

    /// `view` rises 14 points into its place, easing out.
    private func rise(_ view: NSView) {
        view.wantsLayer = true
        let rise = CABasicAnimation(keyPath: "transform.translation.y")
        // the layer's y grows upward: it starts below its place.
        rise.fromValue = -14
        rise.toValue = 0
        rise.duration = 0.26
        rise.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
        view.layer?.add(rise, forKey: "rise")
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

    /// Esc: the words go and search stays open, as when they are deleted; in the empty field,
    /// search ends.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        if search.stringValue.isEmpty {
            endSearch()
        } else {
            search.stringValue = ""
            searchChanged()
        }
        return true
    }

    @objc private func closeSearchClicked() { endSearch() }

    /// The close button comes out of the field's end as the field gives it room; going, it fades
    /// as the field grows back over its place.
    private func showCloseSearch(_ shown: Bool) {
        guard shown != isCloseSearchShown else { return }
        isCloseSearchShown = shown
        let room = search.frame.height + 6
        closeSearch.isHidden = false
        if shown {
            // from under the field's end, small, to its place.
            closeSearch.wantsLayer = true
            let slide = CABasicAnimation(keyPath: "transform")
            slide.fromValue = CATransform3DScale(CATransform3DMakeTranslation(-room / 2, 0, 0), 0.4, 0.4, 1)
            slide.toValue = CATransform3DIdentity
            slide.duration = 0.3
            slide.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 1.25, 0.5, 1)
            closeSearch.layer?.add(slide, forKey: "slide")
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = shown ? 0.3 : 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            searchTrailing.animator().constant = shown ? -10 - room : -10
            closeSearch.animator().alphaValue = shown ? 1 : 0
            view.layoutSubtreeIfNeeded()
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // shown again while it faded: it stays.
                guard let self, !self.isCloseSearchShown else { return }
                self.closeSearch.isHidden = true
            }
        }
    }

    /// Follows the keyboard in the sidebar's window (its `firstResponder` is key-value observing
    /// compliant).
    private func followFocus(in window: NSWindow?) {
        focusChanges = window?.observe(\.firstResponder) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.focusChanged() }
        }
    }

    /// The keyboard went to a view other than the field or what it found, and the field has no
    /// words: the chats show again. Words keep what they found, wherever the keyboard is.
    /// The window itself as first responder is no view: within one `makeFirstResponder` the
    /// window holds the keyboard between the view that resigns and the one that takes it.
    private func focusChanged() {
        guard search.stringValue.isEmpty, content.subviews.first !== list.view,
              view.window?.firstResponder is NSView, !searchHasFocus else { return }
        endSearch()
    }

    /// The field (its field editor is inside it while it edits), the results or a kind's list
    /// has the keyboard.
    private var searchHasFocus: Bool {
        guard let focused = view.window?.firstResponder as? NSView else { return false }
        return [search, results.view, listing?.view].contains { $0.map(focused.isDescendant(of:)) ?? false }
    }

    /// Back to the chats: a kind's list goes, the field empties, and the keyboard, if search had
    /// it, is the chats'.
    private func endSearch() {
        let hadFocus = searchHasFocus
        listing?.removeFromParent()
        listing = nil
        search.stringValue = ""
        search.placeholderString = String(localized: "Search")
        searchModel.search("")
        searchModel.close()
        show(list.view)
        if hadFocus { view.window?.makeFirstResponder(list.initialFocus) }
    }

    /// A result: its chat (at its message), its thread beside its chat, or a link's page.
    private func open(_ target: SearchTarget) {
        switch target {
        case .chat(let row, let focus): onOpen?(row, focus)
        case .thread(let row, let thread): onOpenThread?(row, thread)
        case .link(let url): NSWorkspace.shared.open(url)
        }
    }

    /// One kind, all of it, in place of the results: the field searches it, with the words it has.
    private func showAll(_ kind: SearchKind) {
        let controller = SearchListController(model: searchModel.list(kind), images: session.images)
        controller.onOpen = { [weak self] target in self?.open(target) }
        controller.onBack = { [weak self] in self?.closeList() }
        controller.onCancel = { [weak self] in self?.endSearch() }
        listing?.removeFromParent()
        listing = controller
        addChild(controller)
        search.placeholderString = String(localized: "Search \(kind.title)")
        show(controller.view, .rise)
    }

    /// Back to the results, for the words in the field now.
    private func closeList() {
        guard let listing else { return }
        listing.removeFromParent()
        self.listing = nil
        search.placeholderString = String(localized: "Search")
        searchModel.search(search.stringValue)
        show(results.view)
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

    /// How the sidebar's content changes: the list and search cross-fade; a kind's list rises in
    /// from a little below as it fades in, and fades back out to the results.
    private enum Change { case fade, rise }

    private func show(_ child: NSView, _ change: Change = .fade) {
        guard child.superview != content else { return }
        showCloseSearch(child !== list.view)
        // between search's own views (the results, a kind's list), the keyboard in the one going
        // stays in search: the field takes it before the window would.
        if child !== list.view, let going = content.subviews.first, going !== list.view,
           let focused = view.window?.firstResponder as? NSView, focused.isDescendant(of: going) {
            view.window?.makeFirstResponder(search)
        }
        if content.window != nil {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = change == .rise ? 0.22 : 0.16
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            content.wantsLayer = true
            content.layer?.add(fade, forKey: "content")
        }
        defer { if change == .rise, content.window != nil { rise(child) } }
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

/// The sidebar's search field, which says when the user gives it the keyboard (a click, Cmd-F,
/// Tab): search opens before any words are typed. The window giving it the keyboard as it opens
/// opens nothing.
final class SidebarSearchField: NSSearchField {
    var onFocus: (() -> Void)?
    /// The field went into a window, or out of one.
    var onWindow: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindow?(window)
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        let byUser = [.leftMouseDown, .keyDown].contains(NSApp.currentEvent?.type)
        if became, byUser { onFocus?() }
        return became
    }
}
