import AppKit
import LuxCore

/// The Settings window (Lux > Settings…, Cmd-,): a tab per area, in the window's toolbar, as Mac
/// apps' settings are. One window, reused.
final class SettingsWindowController: NSWindowController {
    convenience init(session: Session, model: SettingsModel, signOut: @escaping () -> Void) {
        let images = session.images
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        for (controller, title, symbol) in [
            (AccountSettingsController(model: model, images: images, signOut: signOut) as NSViewController, String(localized: "Account"), "person.crop.circle"),
            (EncryptionSettingsController(session: session, model: model), String(localized: "Encryption"), "lock"),
        ] {
            let item = NSTabViewItem(viewController: controller)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.title = String(localized: "Settings")
        self.init(window: window)
        Task { await model.load() }
    }
}

/// Lays out settings rows as a two-column form (`NSGridView`, labels right-aligned), as System
/// Settings-era Mac panes do.
@MainActor
func settingsForm(_ rows: [[NSView]]) -> NSView {
    let grid = NSGridView(views: rows)
    grid.rowSpacing = 12
    grid.columnSpacing = 12
    grid.column(at: 0).xPlacement = .trailing
    grid.translatesAutoresizingMaskIntoConstraints = false
    let container = NSView()
    container.addSubview(grid)
    NSLayoutConstraint.activate([
        grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 28),
        grid.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -28),
        grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
        // rows stay at the top; the window takes the form's height.
        grid.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -24).withPriority(.defaultLow),
        grid.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -24),
        container.widthAnchor.constraint(equalToConstant: 520),
    ])
    return container
}

extension NSLayoutConstraint {
    func withPriority(_ priority: NSLayoutConstraint.Priority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}
