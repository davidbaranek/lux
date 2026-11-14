import AppKit
import LuxCore

/// Appearance: the colour of the places without their own (the account keeps it, so every device
/// shows it). A place's own colour is in its menu on the rail.
final class AppearanceSettingsController: NSViewController {
    private let list: ChatListModel
    private let colors = NSPopUpButton(frame: .zero, pullsDown: false)
    /// The colour as chosen here: the list has it a moment later.
    private lazy var theme = list.defaultTheme

    init(list: ChatListModel) {
        self.list = list
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Appearance")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let note = NSTextField(wrappingLabelWithString: String(localized: "For places without their own colour. Right-click a place in the rail to give it one."))
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.preferredMaxLayoutWidth = 340
        view = settingsForm([
            [NSTextField(labelWithString: String(localized: "Places’ colour:")), colors],
            [NSGridCell.emptyContentView, note],
        ])
        update()
    }

    private func update() {
        colors.menu = NSMenu()
        for item in ThemeMenu.items(current: theme, defaultTheme: nil, target: self, action: #selector(choose(_:))) {
            colors.menu?.addItem(item)
        }
        colors.selectItem(at: colors.menu?.items.firstIndex { ($0.representedObject as? ThemeMenu.Choice)?.theme == theme } ?? 0)
    }

    @objc private func choose(_ item: NSMenuItem) {
        guard let theme = (item.representedObject as? ThemeMenu.Choice)?.theme else { return }
        self.theme = theme
        list.setDefaultTheme(theme)
        update()
    }
}
