import AppKit
import LuxCore
import Testing
@testable import Lux

/// The sidebar's search over a demo account of its own, driven as AppKit drives it (the keyboard
/// given to the field, its field editor's typing, deleting and Esc, its clear button) and seen
/// through what the sidebar shows: the results or the chats, and the close button beside the
/// field. The sidebar is in a window that is never shown, so the keyboard has somewhere to be.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct SidebarSearchViewTests {
    @Test func theCloseButtonShowsWhileSearchShowsAndEndsIt() async throws {
        try await DemoAccount.with { session in
            let sidebar = try ShownSidebar(session)
            #expect(!sidebar.showsClose, "the close button shows over the chats")

            // the field searching with no words yet: what chats shared lately.
            try sidebar.type("")
            await sidebar.settled()
            #expect(sidebar.showsResults)
            #expect(sidebar.showsClose, "no close button with an empty field")

            try sidebar.type("a")
            await sidebar.settled()
            #expect(sidebar.showsClose, "no close button with results")

            sidebar.close.performClick(nil)
            await sidebar.settled()
            #expect(!sidebar.showsResults)
            #expect(!sidebar.showsClose)
            #expect(sidebar.field.stringValue.isEmpty)
        }
    }

    @Test func deletingAllTheWordsKeepsSearchWhileTheFieldHasTheKeyboard() async throws {
        try await DemoAccount.with { session in
            let sidebar = try ShownSidebar(session)
            try sidebar.type("a")
            #expect(sidebar.showsResults)

            try sidebar.deleteAll()
            await sidebar.settled()
            #expect(sidebar.field.stringValue.isEmpty)
            #expect(sidebar.showsResults, "deleting the words ended search")
            #expect(sidebar.showsClose)
        }
    }

    @Test func theKeyboardLeavingTheEmptyFieldShowsTheChats() async throws {
        try await DemoAccount.with { session in
            let sidebar = try ShownSidebar(session)
            try sidebar.type("a")
            try sidebar.deleteAll()

            // to the results: search stays.
            #expect(sidebar.window.makeFirstResponder(try sidebar.results))
            #expect(sidebar.showsResults, "the keyboard going to the results ended search")

            // elsewhere: the chats.
            #expect(sidebar.window.makeFirstResponder(sidebar.elsewhere))
            await sidebar.settled()
            #expect(!sidebar.showsResults)
            #expect(!sidebar.showsClose)
        }
    }

    @Test func aKindsListOpenedFromTheResultsKeepsSearch() async throws {
        try await DemoAccount.with { session in
            let sidebar = try ShownSidebar(session)
            try sidebar.type("a")
            try sidebar.deleteAll()
            #expect(sidebar.window.makeFirstResponder(try sidebar.results))

            let links = try #require(sidebar.view("search-kind-links") as? NSButton)
            links.performClick(nil)
            #expect(sidebar.view("search-list") != nil, "the kind's list went as the results' table did")
            #expect(sidebar.fieldHasKeyboard)
        }
    }

    @Test func wordsKeepTheResultsWhereverTheKeyboardGoes() async throws {
        try await DemoAccount.with { session in
            let sidebar = try ShownSidebar(session)
            try sidebar.type("a")

            #expect(sidebar.window.makeFirstResponder(sidebar.elsewhere))
            #expect(sidebar.showsResults)
            #expect(sidebar.field.stringValue == "a")
        }
    }

    @Test func theFieldsClearButtonOnlyClearsTheWords() async throws {
        try await DemoAccount.with { session in
            let sidebar = try ShownSidebar(session)
            try sidebar.type("a")
            #expect(sidebar.showsResults)

            try #require((sidebar.field.cell as? NSSearchFieldCell)?.cancelButtonCell).performClick(sidebar.field)
            await sidebar.settled()
            #expect(sidebar.field.stringValue.isEmpty)
            #expect(sidebar.showsResults, "the field's clear button ended search")
            #expect(sidebar.showsClose)
        }
    }

    @Test func escapeClearsTheWordsThenEndsSearch() async throws {
        try await DemoAccount.with { session in
            let sidebar = try ShownSidebar(session)
            try sidebar.type("a")

            try sidebar.escape()
            #expect(sidebar.field.stringValue.isEmpty)
            #expect(sidebar.showsResults, "Esc with words ended search")

            try sidebar.escape()
            await sidebar.settled()
            #expect(!sidebar.showsResults)
            #expect(!sidebar.showsClose)
            #expect(!sidebar.fieldHasKeyboard)
        }
    }

    @Test func escapeInTheResultsEndsSearch() async throws {
        try await DemoAccount.with { session in
            let sidebar = try ShownSidebar(session)
            try sidebar.type("a")
            #expect(sidebar.window.makeFirstResponder(try sidebar.results))

            // Esc goes up the responder chain from the table, as its key handling sends it.
            #expect(try sidebar.results.tryToPerform(#selector(NSResponder.cancelOperation(_:)), with: nil))
            await sidebar.settled()
            #expect(!sidebar.showsResults)
            #expect(!sidebar.showsClose)
            #expect(sidebar.field.stringValue.isEmpty)
        }
    }
}

/// The sidebar's controller, its view laid out at a sidebar's size in a window that is never
/// shown, beside a text view standing for the rest of the window (a chat's composer), with its
/// search field, its close button and what shows under them.
@MainActor
private struct ShownSidebar {
    let controller: SidebarController
    let window: NSWindow
    let field: NSSearchField
    let close: NSButton
    /// A view outside the sidebar that takes the keyboard.
    let elsewhere = NSTextView(frame: NSRect(x: 360, y: 0, width: 300, height: 900))

    init(_ session: Session) throws {
        controller = SidebarController(session: session)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 900), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        controller.view.frame = NSRect(x: 0, y: 0, width: 360, height: 900)
        window.contentView?.addSubview(controller.view)
        window.contentView?.addSubview(elsewhere)
        controller.view.layoutSubtreeIfNeeded()
        field = try #require(controller.view.subviews.lazy.compactMap { $0 as? NSSearchField }.first)
        close = try #require(controller.view.subviews.lazy.compactMap { $0 as? NSButton }
            .first { $0.accessibilityIdentifier() == "close-search" })
    }

    /// Returns once the animations started so far have ended.
    func settled() async {
        await withCheckedContinuation { done in
            NSAnimationContext.runAnimationGroup { _ in } completionHandler: { done.resume() }
        }
    }

    /// The close button is on screen beside the field.
    var showsClose: Bool { !close.isHidden && close.alphaValue > 0 }

    /// The field's field editor while the field has the keyboard (given to it first).
    private func editor() throws -> NSTextView {
        if !fieldHasKeyboard { #expect(window.makeFirstResponder(field)) }
        return try #require(field.currentEditor() as? NSTextView)
    }

    /// Words typed in the field: its field editor inserts them, then the field sends its action.
    func type(_ text: String) throws {
        try editor().insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        sendAction()
    }

    /// The words deleted to the last letter, in the field editor, then the field's action.
    func deleteAll() throws {
        let editor = try editor()
        editor.selectAll(nil)
        editor.deleteBackward(nil)
        sendAction()
    }

    /// The field sends its action for an edit on the run loop's next turn, even sending its string
    /// at once: sent here now, the step is seen at once (the field's own, later, sends the same
    /// string again).
    private func sendAction() {
        field.sendAction(field.action, to: field.target)
    }

    /// Esc in the field: its field editor asks the field's delegate first.
    func escape() throws {
        try editor().doCommand(by: #selector(NSResponder.cancelOperation(_:)))
    }

    /// The field's field editor has the keyboard.
    var fieldHasKeyboard: Bool { (window.firstResponder as? NSView)?.isDescendant(of: field) ?? false }

    /// The search's results' table, shown in the sidebar.
    var results: NSView {
        get throws { try #require(view("search-results")) }
    }

    /// The search's results are in the sidebar (not the chats).
    var showsResults: Bool { view("search-results") != nil }

    /// The view in the sidebar with this accessibility identifier.
    func view(_ identifier: String) -> NSView? { descendant(of: controller.view) { $0.accessibilityIdentifier() == identifier } }

    private func descendant(of view: NSView, where matches: (NSView) -> Bool) -> NSView? {
        if matches(view) { return view }
        for subview in view.subviews {
            if let found = descendant(of: subview, where: matches) { return found }
        }
        return nil
    }
}
