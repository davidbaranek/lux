import AppKit
import LuxCore

/// The rail: a narrow column left of the chat list, a little darker than the sidebar, with a button
/// for each place (folders, networks, spaces) and the account at its foot. Under the traffic lights
/// its tint fades into the sidebar's material.
final class RailController: NSViewController {
    static let width: CGFloat = 62

    var onSelect: ((Place) -> Void)?
    /// A place hidden from the rail (true) or shown again; nil shows every hidden place.
    var onHide: ((Place?, Bool) -> Void)?
    /// A place's own colour chosen, or (nil) the one for every place.
    var onTheme: ((Place, PlaceTheme?) -> Void)?
    /// How much of a network's or a space's chats the inbox shows, chosen.
    var onInbox: ((Place, InboxRule) -> Void)?
    /// A network's or a space's chats are to notify so.
    var onNotifications: ((Place, NotificationSetting) -> Void)?
    /// The colour of the places without their own: the menu's Default names it.
    var defaultTheme = PlaceTheme.neutral
    var onAccount: (() -> Void)?

    private let images: ImagePipeline?
    private let stack = NSStackView()
    private var buttons: [Place: RailButton] = [:]
    private let account = AvatarView(side: 30)
    private var selected: Place = .inbox
    /// Every place, the hidden ones too: the rail's menu offers those back.
    private var items: [PlaceItem] = []

    init(images: ImagePipeline?) {
        self.images = images
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let background = RailBackground()
        // right click on the rail: show the places hidden from it again.
        background.menuProvider = { [weak self] in self?.hiddenMenu() }
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        let document = FlippedView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        let scroll = NSScrollView()
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.automaticallyAdjustsContentInsets = false
        // the first button starts under the traffic lights' row.
        scroll.contentInsets = NSEdgeInsets(top: 56, left: 0, bottom: 8, right: 0)

        let accountButton = NSButton(title: "", target: self, action: #selector(openAccount))
        accountButton.isBordered = false
        accountButton.setAccessibilityLabel(String(localized: "Settings"))
        accountButton.toolTip = String(localized: "Settings")
        for view in [scroll, account, accountButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(view)
        }
        document.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            background.widthAnchor.constraint(equalToConstant: Self.width),
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: background.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: account.topAnchor, constant: -10),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            account.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            account.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -14),
            accountButton.leadingAnchor.constraint(equalTo: account.leadingAnchor),
            accountButton.trailingAnchor.constraint(equalTo: account.trailingAnchor),
            accountButton.topAnchor.constraint(equalTo: account.topAnchor),
            accountButton.bottomAnchor.constraint(equalTo: account.bottomAnchor),
        ])
        view = background
    }

    /// Shows the places, but those the user hid (unless it is the one shown), reusing the buttons
    /// of places that stay.
    func show(_ items: [PlaceItem], selected: Place) {
        self.items = items
        self.selected = selected
        var kept: [Place: RailButton] = [:]
        var views: [NSView] = []
        var previousGroup: Place.Group?
        for item in items where !item.isHidden || item.id == selected {
            // a line between the folders, the networks, the spaces and the labels.
            let group = item.id.group
            if let previousGroup, previousGroup != group { views.append(RailSeparator()) }
            previousGroup = group
            let button = buttons[item.id] ?? RailButton { [weak self] place in self?.onSelect?(place) }
            button.menuProvider = { [weak self] place in self?.menu(for: place) }
            button.show(item, selected: item.id == selected, images: images)
            kept[item.id] = button
            views.append(button)
        }
        buttons = kept
        if stack.arrangedSubviews != views { stack.setViews(views, in: .top) }
    }

    func select(_ place: Place) {
        let wasHidden = items.first { $0.id == selected }?.isHidden == true
        selected = place
        // a hidden place leaves the rail once another is chosen.
        if wasHidden || buttons[place] == nil { return show(items, selected: place) }
        for (id, button) in buttons { button.isSelected = id == place }
    }

    // MARK: Hiding places

    /// A place's menu: its colour; for a network or a space, how much of it the inbox shows and
    /// when its chats notify; hide it (all but the inbox), and the hidden ones to show again.
    private func menu(for place: Place) -> NSMenu? {
        let menu = NSMenu()
        if let item = items.first(where: { $0.id == place }) {
            let colour = NSMenuItem(title: String(localized: "Colour"), action: nil, keyEquivalent: "")
            colour.image = NSImage(systemSymbolName: "paintpalette", accessibilityDescription: nil)
            let submenu = NSMenu()
            for entry in ThemeMenu.items(current: item.ownTheme, defaultTheme: defaultTheme, target: self,
                                         action: #selector(choseTheme(_:)), place: place) {
                submenu.addItem(entry)
            }
            colour.submenu = submenu
            menu.addItem(colour)
            if let current = item.inbox {
                menu.addItem(InboxMenu.item(place: place, current: current, target: self, action: #selector(choseInbox(_:))))
                menu.addItem(NotificationMenu.item(place: place, current: item.notifications, target: self,
                                                   action: #selector(choseNotifications(_:))))
            }
            menu.addItem(.separator())
        }
        if place != .inbox, let item = items.first(where: { $0.id == place }) {
            let hide = NSMenuItem(title: String(localized: "Hide \(item.title)"), action: #selector(hidePlace(_:)), keyEquivalent: "")
            hide.target = self
            hide.representedObject = place
            hide.image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: nil)
            menu.addItem(hide)
        }
        if let hidden = hiddenMenu() {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            let moved = hidden.items
            hidden.removeAllItems()
            moved.forEach(menu.addItem)
        }
        return menu.items.isEmpty ? nil : menu
    }

    /// "Show Hidden Places" with each hidden place, and Show All; nil while none is hidden.
    private func hiddenMenu() -> NSMenu? {
        let places = items.filter(\.isHidden)
        guard !places.isEmpty else { return nil }
        let menu = NSMenu()
        let header = NSMenuItem(title: String(localized: "Show Hidden Places"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for item in places {
            let entry = NSMenuItem(title: item.title, action: #selector(showPlace(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = item.id
            submenu.addItem(entry)
        }
        submenu.addItem(.separator())
        let all = NSMenuItem(title: String(localized: "Show All"), action: #selector(showPlace(_:)), keyEquivalent: "")
        all.target = self
        submenu.addItem(all)
        header.submenu = submenu
        header.image = NSImage(systemSymbolName: "eye", accessibilityDescription: nil)
        menu.addItem(header)
        return menu
    }

    @objc private func choseTheme(_ item: NSMenuItem) {
        guard let choice = item.representedObject as? ThemeMenu.Choice, let place = choice.place else { return }
        onTheme?(place, choice.theme)
    }

    @objc private func choseInbox(_ item: NSMenuItem) {
        guard let choice = item.representedObject as? InboxMenu.Choice else { return }
        onInbox?(choice.place, choice.rule)
    }

    @objc private func choseNotifications(_ item: NSMenuItem) {
        guard let choice = item.representedObject as? NotificationMenu.Choice, let place = choice.place else { return }
        onNotifications?(place, choice.setting)
    }

    @objc private func hidePlace(_ item: NSMenuItem) {
        guard let place = item.representedObject as? Place else { return }
        onHide?(place, true)
    }

    /// Shows one hidden place again, or all of them (an item with no place).
    @objc private func showPlace(_ item: NSMenuItem) {
        onHide?(item.representedObject as? Place, false)
    }

    func showAccount(_ profile: Profile?) {
        account.show(profile?.avatar, name: profile?.name ?? "", images: images)
    }

    @objc private func openAccount() { onAccount?() }
}

/// The rail's tint over the sidebar material: a little darker, fading out under the traffic lights,
/// with a hairline on its trailing edge. Colours resolve again when the appearance changes.
private final class RailBackground: NSView {
    var menuProvider: (() -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
    private let tint = CALayer()
    private let fade = CAGradientLayer()
    private let line = CALayer()
    private let lineFade = CAGradientLayer()
    /// The traffic lights' row stays the sidebar's own colour; below it the tint and the hairline
    /// fade in together over a long run, so the rail blends into the sidebar at the top.
    private static let clearUntil: CGFloat = 36
    private static let fullFrom: CGFloat = 110

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(tint)
        layer?.addSublayer(line)
        fade.colors = [NSColor.clear.cgColor, NSColor.clear.cgColor, NSColor.black.cgColor]
        tint.mask = fade
        lineFade.colors = fade.colors
        line.mask = lineFade
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        tint.backgroundColor = NSColor.black.withAlphaComponent(dark ? 0.22 : 0.06).cgColor
        line.backgroundColor = NSColor.separatorColor.cgColor
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tint.frame = bounds
        fade.frame = bounds
        // the layer's origin is at the bottom: the gradient runs from the top edge (location 0) down.
        let height = max(bounds.height, Self.fullFrom)
        fade.startPoint = CGPoint(x: 0.5, y: 1)
        fade.endPoint = CGPoint(x: 0.5, y: 0)
        fade.locations = [0, NSNumber(value: Self.clearUntil / height), NSNumber(value: Self.fullFrom / height)]
        let scale = window?.backingScaleFactor ?? 2
        line.frame = CGRect(x: bounds.width - 1 / scale, y: 0, width: 1 / scale, height: bounds.height)
        lineFade.frame = line.bounds
        lineFade.startPoint = CGPoint(x: 0.5, y: 1)
        lineFade.endPoint = CGPoint(x: 0.5, y: 0)
        let lineHeight = max(bounds.height, Self.fullFrom)
        lineFade.locations = [0, NSNumber(value: Self.clearUntil / lineHeight), NSNumber(value: Self.fullFrom / lineHeight)]
        CATransaction.commit()
    }
}

private final class RailSeparator: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 32), heightAnchor.constraint(equalToConstant: 1)])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.separatorColor.cgColor }
}
