import AppKit
import LuxCore
import Testing
@testable import Lux

/// The Settings window over a demo account of its own, as System Settings is: the pane picked in
/// the sidebar shows beside it with its title, back and forward walk the panes shown, and a new
/// window opens on the pane shown last. Seen through what AppKit shows: the window's title, the
/// pane's view in it, and the toolbar's back and forward.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct SettingsViewTests {
    @Test func aPickedPaneShowsWithItsTitleAndBackAndForwardWalkThem() async throws {
        try await withSettings { session, defaults in
            let settings = open(session, defaults)
            let window = try #require(settings.window)
            #expect(window.title == SettingsPane.account.title, "a first window opens on Account")
            #expect(shows(.account, in: window))
            #expect(!navigation(window, 0).isEnabled, "back with nothing to go back to")

            settings.show(.search)
            #expect(window.title == SettingsPane.search.title)
            #expect(shows(.search, in: window))
            #expect(!shows(.account, in: window), "the pane before stays in the window")
            settings.show(.ai)

            try go(window, back: true)
            #expect(window.title == SettingsPane.search.title)
            #expect(shows(.search, in: window))
            #expect(navigation(window, 1).isEnabled)

            try go(window, back: true)
            #expect(window.title == SettingsPane.account.title)
            #expect(!navigation(window, 0).isEnabled)

            try go(window, back: false)
            #expect(window.title == SettingsPane.search.title)

            // a pane picked after going back drops the ones ahead.
            settings.show(.encryption)
            #expect(!navigation(window, 1).isEnabled)
        }
    }

    @Test func aNewWindowOpensOnThePaneShownLast() async throws {
        try await withSettings { session, defaults in
            open(session, defaults).show(.search)
            let window = try #require(open(session, defaults).window)
            #expect(window.title == SettingsPane.search.title)
            #expect(shows(.search, in: window))
        }
    }

    /// Runs `test` over a demo session, with defaults (where Settings keeps its pane) of the test's own.
    private func withSettings(_ test: @MainActor (Session, UserDefaults) async throws -> Void) async throws {
        try await DemoAccount.with(rooms: 5) { session in
            let name = "lux-settings-tests-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: name))
            defer { defaults.removePersistentDomain(forName: name) }
            try await test(session, defaults)
        }
    }

    /// A Settings window, never shown.
    private func open(_ session: Session, _ defaults: UserDefaults) -> SettingsWindowController {
        SettingsWindowController(session: session, model: SettingsModel(session: session), list: nil, defaults: defaults) {}
    }

    private func shows(_ pane: SettingsPane, in window: NSWindow) -> Bool {
        func find(_ view: NSView) -> Bool {
            view.identifier?.rawValue == "settings.\(pane.rawValue)" || view.subviews.contains(where: find)
        }
        return window.contentView.map(find) ?? false
    }

    private func navigation(_ window: NSWindow, _ index: Int) -> NSToolbarItem {
        let group = window.toolbar?.items.first { $0.itemIdentifier == .settingsNavigation } as? NSToolbarItemGroup
        return group?.subitems[safe: index] ?? NSToolbarItem(itemIdentifier: .init("missing"))
    }

    /// Clicks back or forward, as the toolbar's segment does.
    private func go(_ window: NSWindow, back: Bool) throws {
        let group = try #require(window.toolbar?.items.first { $0.itemIdentifier == .settingsNavigation } as? NSToolbarItemGroup)
        group.selectedIndex = back ? 0 : 1
        #expect(NSApp.sendAction(try #require(group.action), to: group.target, from: group))
    }
}
