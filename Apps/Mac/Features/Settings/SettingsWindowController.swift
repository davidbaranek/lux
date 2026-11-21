import AppKit
import LuxCore
import SwiftUI

/// A pane of Settings: a row of the window's sidebar.
enum SettingsPane: String, CaseIterable, Identifiable {
    case account, appearance, networks, encryption, search, ai

    var id: Self { self }

    var title: String {
        switch self {
        case .account: String(localized: "Account")
        case .appearance: String(localized: "Appearance")
        case .networks: String(localized: "Networks")
        case .encryption: String(localized: "Encryption")
        case .search: String(localized: "Search")
        case .ai: String(localized: "AI")
        }
    }

    /// Its symbol and the colour of the tile under it, as System Settings shows its panes.
    var symbol: String {
        switch self {
        case .account: "person.crop.circle.fill"
        case .appearance: "paintpalette.fill"
        case .networks: "point.3.connected.trianglepath.dotted"
        case .encryption: "lock.fill"
        case .search: "magnifyingglass"
        case .ai: "apple.intelligence"
        }
    }

    var color: Color {
        switch self {
        case .account: .blue
        case .appearance: .indigo
        case .networks: .green
        case .encryption: .gray
        case .search: .teal
        case .ai: .purple
        }
    }
}

/// The Settings window (Lux > Settings…, Cmd-,), as System Settings is: the panes in a sidebar
/// under a search field, the chosen one beside it with its title and back and forward in the
/// toolbar. Search lists the settings that match, by pane, in the sidebar; one picked opens its pane
/// at its row. One window, reused; it opens on the pane it showed last, at the size it had.
final class SettingsWindowController: NSWindowController, NSToolbarDelegate, NSSearchFieldDelegate {
    private let panes: [SettingsPane: NSViewController]
    private let order: [SettingsPane]
    private let defaults: UserDefaults
    private let content = PaneContainer()
    private let sidebar = SettingsSidebarController()
    /// What the search field asks, and the setting last picked from what it found.
    private var query = ""
    private var found: SettingsItem?
    /// The panes shown, in order, and which of them shows now: back and forward walk them.
    private var history: [SettingsPane] = []
    private var position = -1
    private lazy var navigation = NSToolbarItemGroup(
        itemIdentifier: .settingsNavigation,
        images: [NSImage(systemSymbolName: "chevron.backward", accessibilityDescription: String(localized: "Back")) ?? NSImage(),
                 NSImage(systemSymbolName: "chevron.forward", accessibilityDescription: String(localized: "Forward")) ?? NSImage()],
        selectionMode: .momentary,
        labels: [String(localized: "Back"), String(localized: "Forward")],
        target: self,
        action: #selector(navigate(_:))
    )

    private static let lastPane = "SettingsPane"
    private static let frameName = "Settings"

    init(session: Session, model: SettingsModel, list: ChatListModel?, defaults: UserDefaults = .standard,
         signOut: @escaping () -> Void) {
        var panes: [SettingsPane: NSViewController] = [
            .account: AccountSettingsController(model: model, profile: session.profile, images: session.images, signOut: signOut),
            .encryption: EncryptionSettingsController(session: session, model: model),
            .search: SearchSettingsController(model: model),
            .ai: AISettingsController(session: session),
        ]
        if let list { panes[.appearance] = AppearanceSettingsController(list: list) }
        if let networks = session.networks { panes[.networks] = NetworksSettingsController(model: networks) }
        self.panes = panes
        order = SettingsPane.allCases.filter { panes[$0] != nil }
        self.defaults = defaults

        let split = NSSplitViewController()
        let side = NSSplitViewItem(sidebarWithViewController: sidebar)
        side.canCollapse = false
        side.minimumThickness = 220
        side.maximumThickness = 320
        split.addSplitViewItem(side)
        split.addSplitViewItem(NSSplitViewItem(viewController: content))
        split.splitView.autosaveName = "SettingsSidebar"

        let window = NSWindow(contentViewController: split)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 715, height: 640))
        window.contentMinSize = NSSize(width: 600, height: 420)
        super.init(window: window)
        sidebar.search.target = self
        sidebar.search.action = #selector(searched(_:))
        sidebar.search.delegate = self

        let toolbar = NSToolbar(identifier: "Settings")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        navigation.isNavigational = true
        navigation.autovalidates = false
        // AppKit keeps a window's frame in the standard defaults only: with defaults of their own
        // (a test's), the window keeps nothing there either.
        if defaults == .standard, window.setFrameUsingName(Self.frameName) {
            window.setFrameAutosaveName(Self.frameName)
        } else {
            window.center()
            if defaults == .standard { window.setFrameAutosaveName(Self.frameName) }
        }

        let last = defaults.string(forKey: Self.lastPane).flatMap(SettingsPane.init(rawValue:))
        show(last.flatMap { order.contains($0) ? $0 : nil } ?? order[0])
        Task { await model.load() }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// The pane showing now.
    var current: SettingsPane? { history.indices.contains(position) ? history[position] : nil }

    /// Shows `pane`, as the sidebar does when it is picked: it goes after the one showing in the
    /// history, in place of any the window had gone back from.
    func show(_ pane: SettingsPane) {
        guard pane != current, panes[pane] != nil else { return }
        history = Array(history.prefix(position + 1)) + [pane]
        position = history.count - 1
        display()
    }

    /// Shows `item`'s pane scrolled to its row, as a search result does when it is picked.
    func show(_ item: SettingsItem) {
        found = item
        show(item.pane)
        updateSidebar()
        (panes[item.pane] as? SearchablePane)?.focus.reveal(item)
    }

    @objc private func searched(_ sender: NSSearchField) {
        query = sender.stringValue.trimmingCharacters(in: .whitespaces)
        found = nil
        updateSidebar()
    }

    /// Edit > Find > Find… (Cmd-F): the keyboard goes to the search field.
    @objc func performFindPanelAction(_ sender: Any?) {
        window?.makeFirstResponder(sidebar.search)
    }

    /// In the search field, Down goes to what it found, opening the first, and Return opens the
    /// first, as in System Settings.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.moveDown(_:)) || selector == #selector(NSResponder.insertNewline(_:)),
              let first = SettingsItem.matching(query, in: order).first else { return false }
        show(first)
        if selector == #selector(NSResponder.moveDown(_:)) { window?.makeFirstResponder(sidebar.results) }
        return true
    }

    @objc private func navigate(_ sender: NSToolbarItemGroup) {
        let step = sender.selectedIndex == 0 ? -1 : 1
        guard history.indices.contains(position + step) else { return }
        position += step
        display()
    }

    private func display() {
        guard let pane = current, let controller = panes[pane] else { return }
        content.show(controller, id: pane.rawValue)
        window?.title = pane.title
        updateSidebar()
        navigation.subitems[0].isEnabled = position > 0
        navigation.subitems[1].isEnabled = position < history.count - 1
        defaults.set(pane.rawValue, forKey: Self.lastPane)
    }

    /// The panes, or while searching what search found.
    private func updateSidebar() {
        let results = query.isEmpty ? [] : SettingsItem.matching(query, in: order)
        let selected: SettingsSidebar.Row? = query.isEmpty ? current.map { .pane($0) } : found.map { .item($0) }
        sidebar.list.rootView = SettingsSidebar(panes: query.isEmpty ? order : [], results: results, selected: selected) { [weak self] row in
            switch row {
            case .pane(let pane): self?.show(pane)
            case .item(let item): self?.show(item)
            }
        }
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarTrackingSeparator, .settingsNavigation]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        identifier == .settingsNavigation ? navigation : nil
    }
}

extension NSToolbarItem.Identifier {
    static let settingsNavigation = Self("settings.navigation")
}

/// The window's right side: the pane showing, filling it.
private final class PaneContainer: NSViewController {
    override func loadView() {
        view = NSView()
    }

    func show(_ pane: NSViewController, id: String) {
        for child in children {
            child.view.removeFromSuperview()
            child.removeFromParent()
        }
        addChild(pane)
        pane.view.identifier = NSUserInterfaceItemIdentifier("settings.\(id)")
        pane.view.frame = view.bounds
        pane.view.autoresizingMask = [.width, .height]
        view.addSubview(pane.view)
    }
}

/// The sidebar: the search field over the list, under the window's title bar, as System Settings
/// has it.
private final class SettingsSidebarController: NSViewController {
    let search = NSSearchField()
    let list = NSHostingController(rootView: SettingsSidebar(panes: [], results: [], selected: nil, select: { _ in }))

    /// The table the list draws in, which takes the keyboard from the field.
    var results: NSView? {
        func table(in view: NSView) -> NSView? {
            view is NSTableView ? view : view.subviews.lazy.compactMap(table).first
        }
        return table(in: list.view)
    }

    override func loadView() {
        search.placeholderString = String(localized: "Search")
        search.controlSize = .large
        search.sendsSearchStringImmediately = true
        search.identifier = NSUserInterfaceItemIdentifier("settings.search")
        let view = NSView()
        addChild(list)
        for subview in [search, list.view] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        // the field spans what a selected row does, as System Settings' does: the sidebar list
        // style insets its rows' selection by 10 points.
        let inset: CGFloat = 10
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            search.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: inset),
            search.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -inset),
            list.view.topAnchor.constraint(equalToSystemSpacingBelow: search.bottomAnchor, multiplier: 1),
            list.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            list.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            list.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        self.view = view
    }
}

/// The panes, each a symbol on its coloured tile beside its name; while searching, the settings
/// found, under their panes.
struct SettingsSidebar: View {
    enum Row: Hashable {
        case pane(SettingsPane)
        case item(SettingsItem)
    }

    let panes: [SettingsPane]
    let results: [SettingsItem]
    let selected: Row?
    let select: @MainActor (Row) -> Void

    var body: some View {
        List(selection: Binding(get: { selected }, set: { if let row = $0 { select(row) } })) {
            ForEach(panes) { pane in
                Label { Text(pane.title) } icon: { SymbolTile(symbol: pane.symbol, color: pane.color) }
                    .tag(Row.pane(pane))
            }
            // each pane's name over what was found in it. Not a `Section`: a sidebar's sections
            // fold, and one made anew while typing comes folded.
            ForEach(results) { item in
                if item == results.first(where: { $0.pane == item.pane }) {
                    Text(item.pane.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                        .padding(.top, 6)
                }
                Label { Text(item.title) } icon: { SymbolTile(symbol: item.pane.symbol, color: item.pane.color) }
                    .tag(Row.item(item))
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if panes.isEmpty, results.isEmpty {
                Text(String(localized: "No Results")).foregroundStyle(.secondary)
            }
        }
    }
}

/// A symbol in white on a rounded square of `color`, as System Settings marks its panes and rows.
struct SymbolTile: View {
    let symbol: String
    let color: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

/// An `AvatarView` in a SwiftUI form.
struct Avatar: NSViewRepresentable {
    let ref: ImageRef?
    let name: String
    let side: CGFloat
    let images: ImagePipeline?

    func makeNSView(context: Context) -> AvatarView {
        AvatarView(side: side)
    }

    func updateNSView(_ view: AvatarView, context: Context) {
        view.show(ref, name: name, images: images)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AvatarView, context: Context) -> CGSize? {
        CGSize(width: side, height: side)
    }
}
