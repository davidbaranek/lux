import AppKit
import LuxCore
import Testing
@testable import Lux

/// The sidebar's search over a demo account of its own, driven through its field as AppKit drives
/// it (its string, its action, its delegate's calls, its clear button) and seen through what the
/// sidebar shows: the results or the chats, and the close button beside the field. No window.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct SidebarSearchViewTests {
    @Test func deletingAllTheWordsKeepsSearchOpenUntilItIsClosed() async throws {
        try await DemoAccount.with { session in
            let sidebar = try ShownSidebar(session)
            sidebar.type("a")
            await sidebar.settled()
            #expect(sidebar.showsResults)
            #expect(sidebar.showsClose)

            sidebar.deleteAll()
            await sidebar.settled()
            #expect(sidebar.showsResults, "deleting the words ended search")
            #expect(sidebar.showsClose, "the close button went with the words")

            sidebar.close.performClick(nil)
            await sidebar.settled()
            #expect(!sidebar.showsResults)
            #expect(!sidebar.showsClose)
        }
    }

    @Test func theFieldsClearButtonEndsSearch() async throws {
        try await DemoAccount.with { session in
            let sidebar = try ShownSidebar(session)
            sidebar.type("a")
            await sidebar.settled()
            #expect(sidebar.showsResults)

            try #require((sidebar.field.cell as? NSSearchFieldCell)?.cancelButtonCell).performClick(sidebar.field)
            await sidebar.settled()
            #expect(sidebar.field.stringValue.isEmpty)
            #expect(!sidebar.showsResults)
            #expect(!sidebar.showsClose)
        }
    }

    @Test func escapeClearsTheWordsThenEndsSearch() async throws {
        try await DemoAccount.with { session in
            let sidebar = try ShownSidebar(session)
            sidebar.type("a")
            await sidebar.settled()

            #expect(sidebar.escape())
            await sidebar.settled()
            #expect(sidebar.field.stringValue.isEmpty)
            #expect(sidebar.showsResults, "Esc with words ended search")
            #expect(sidebar.showsClose)

            #expect(sidebar.escape())
            await sidebar.settled()
            #expect(!sidebar.showsResults)
            #expect(!sidebar.showsClose)
        }
    }
}

/// The sidebar's controller, its view loaded and laid out at a sidebar's size, with its search
/// field, its close button and what shows under them.
@MainActor
private struct ShownSidebar {
    let controller: SidebarController
    let field: NSSearchField
    let close: NSButton

    init(_ session: Session) throws {
        controller = SidebarController(session: session)
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 360, height: 900)
        controller.view.layoutSubtreeIfNeeded()
        field = try #require(controller.view.subviews.lazy.compactMap { $0 as? NSSearchField }.first)
        close = try #require(controller.view.subviews.lazy.compactMap { $0 as? NSButton }
            .first { $0.accessibilityIdentifier() == "close-search" })
    }

    /// Words typed: the field, which sends its string at once, sends its action.
    func type(_ text: String) {
        field.stringValue = text
        field.sendAction(field.action, to: field.target)
    }

    /// The words deleted to the last letter: the field empties, which has AppKit tell its
    /// delegate searching ended, then sends its action with the empty string (the order a field
    /// editor's deleting gives).
    func deleteAll() {
        field.stringValue = ""
        field.sendAction(field.action, to: field.target)
    }

    /// Esc in the field: its field editor asks the delegate first. True when the delegate took it.
    func escape() -> Bool {
        field.delegate?.control?(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))) ?? false
    }

    /// Returns once the animations started so far have ended.
    func settled() async {
        await withCheckedContinuation { done in
            NSAnimationContext.runAnimationGroup { _ in } completionHandler: { done.resume() }
        }
    }

    /// The search's results are in the sidebar (not the chats).
    var showsResults: Bool { descendant(of: controller.view) { $0.accessibilityIdentifier() == "search-results" } }

    /// The close button is on screen beside the field.
    var showsClose: Bool { !close.isHidden && close.alphaValue > 0 }

    private func descendant(of view: NSView, where matches: (NSView) -> Bool) -> Bool {
        matches(view) || view.subviews.contains { descendant(of: $0, where: matches) }
    }
}
