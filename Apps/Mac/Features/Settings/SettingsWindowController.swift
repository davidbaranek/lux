import AppKit
import LuxCore

/// The Settings window (Lux > Settings…, Cmd-,): a tab per area, in the window's toolbar, as Mac
/// apps' settings are. One window, reused.
final class SettingsWindowController: NSWindowController {
    convenience init(session: Session, model: SettingsModel, list: ChatListModel?, signOut: @escaping () -> Void) {
        let images = session.images
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        var panes: [(NSViewController, String, String)] = [
            (AccountSettingsController(model: model, profile: session.profile, images: images, signOut: signOut), String(localized: "Account"), "person.crop.circle"),
        ]
        if let list {
            panes.append((AppearanceSettingsController(list: list), String(localized: "Appearance"), "paintpalette"))
        }
        if let networks = session.networks {
            panes.append((NetworksController(model: networks, mode: .settings), String(localized: "Networks"), "point.3.connected.trianglepath.dotted"))
        }
        panes.append((EncryptionSettingsController(session: session, model: model), String(localized: "Encryption"), "lock"))
        panes.append((SearchSettingsController(model: model), String(localized: "Search"), "magnifyingglass"))
        panes.append((AISettingsController(actions: session.textActions), String(localized: "AI"), "apple.intelligence"))
        panes.append((AgentsSettingsController(session: session), String(localized: "Agents"), "terminal"))
        for (controller, title, symbol) in panes {
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
        // rows stay at the top; the window takes the form's height. Below the rows' hugging
        // (250), so a window taller than the form never stretches a row; above the fitting size's
        // compression (50), so the form's height still sizes the window.
        grid.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -24).withPriority(.init(200)),
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
