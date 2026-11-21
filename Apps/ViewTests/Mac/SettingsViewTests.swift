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

    @Test func searchListsTheSettingsFoundAndOnePickedOpensItsPane() async throws {
        try await withSettings { session, defaults in
            let settings = open(session, defaults)
            let window = try #require(settings.window)
            let field = try #require(find(NSSearchField.self, in: window.contentView) { $0.identifier?.rawValue == "settings.search" })
            let list = try #require(find(NSTableView.self, in: field.superview) { _ in true })
            await settled(window)
            #expect(list.numberOfRows == SettingsPane.allCases.count - 1, "the panes, Appearance aside (no chat list)")

            // "Key backup" and "Recovery key", under their pane's heading.
            field.stringValue = "recovery key"
            #expect(NSApp.sendAction(try #require(field.action), to: field.target, from: field))
            await settled(window)
            #expect(list.numberOfRows == 3, "\(list.numberOfRows) rows")

            list.selectRowIndexes([2], byExtendingSelection: false)
            await settled(window)
            #expect(window.title == SettingsPane.encryption.title)
            #expect(shows(.encryption, in: window))

            field.stringValue = "no such setting"
            #expect(NSApp.sendAction(try #require(field.action), to: field.target, from: field))
            await settled(window)
            #expect(list.numberOfRows == 0)
        }
    }

    /// Recovery key is under the account's devices, out of sight until the pane scrolls to it.
    @Test func aSettingFoundIsScrolledToAndMarked() async throws {
        try await withSettings { session, defaults in
            let settings = open(session, defaults)
            let window = try #require(settings.window)
            settings.show(.encryption)
            await settled(window)
            let pane = try #require(find(NSView.self, in: window.contentView) { $0.identifier?.rawValue == "settings.encryption" })
            let clip = try #require(find(NSScrollView.self, in: pane) { _ in true }?.contentView)
            clip.postsBoundsChangedNotifications = true
            #expect(clip.bounds.minY <= 0, "the pane opens at its top")

            settings.show(SettingsItem.recoveryKey)
            let focus = try #require((pane.nextResponder as? SearchablePane)?.focus)
            for await marked in Observations({ focus.marked }) where marked == SettingsItem.recoveryKey.id { break }
            if clip.bounds.minY <= 0 {
                for await _ in NotificationCenter.default.notifications(named: NSView.boundsDidChangeNotification, object: clip)
                where clip.bounds.minY > 0 { break }
            }
            #expect(clip.bounds.minY > 0, "the pane did not scroll to the setting")
        }
    }

    @Test func findTakesTheKeyboardToSearchAndDownOpensWhatItFound() async throws {
        try await withSettings { session, defaults in
            let settings = open(session, defaults)
            let window = try #require(settings.window)
            let field = try #require(find(NSSearchField.self, in: window.contentView) { $0.identifier?.rawValue == "settings.search" })

            // Edit > Find > Find…, as the menu sends it to the key window's responders.
            #expect(window.tryToPerform(#selector(NSTextView.performFindPanelAction(_:)), with: nil))
            let editor = try #require(field.currentEditor() as? NSTextView, "the field does not have the keyboard")

            editor.insertText("agents", replacementRange: editor.selectedRange())
            await settled(window)
            editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
            await settled(window)
            #expect(window.title == SettingsPane.ai.title)
            #expect(window.firstResponder is NSTableView, "Down left the keyboard in the field")

            #expect(window.makeFirstResponder(field))
            let again = try #require(field.currentEditor() as? NSTextView)
            again.selectAll(nil)
            again.insertText("receipts", replacementRange: again.selectedRange())
            await settled(window)
            again.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            #expect(window.title == SettingsPane.account.title, "Return did not open what search found")
        }
    }

    /// SwiftUI has made its views again from what the window controller gave it.
    private func settled(_ window: NSWindow) async {
        for _ in 0..<3 {
            await Task.yield()
            window.contentView?.layoutSubtreeIfNeeded()
        }
    }

    private func find<View: NSView>(_ type: View.Type, in root: NSView?, where test: (View) -> Bool) -> View? {
        guard let root else { return nil }
        if let view = root as? View, test(view) { return view }
        for subview in root.subviews {
            if let found = find(type, in: subview, where: test) { return found }
        }
        return nil
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
