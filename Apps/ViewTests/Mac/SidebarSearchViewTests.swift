import AppKit
import LuxCore
import Testing
@testable import Lux

/// The sidebar's search over a demo account of its own, driven as AppKit drives it (the keyboard
/// given to the field, its field editor's typing, deleting and Esc, its clear button) and seen
/// through what the sidebar shows: the results or the chats. The sidebar is in a window that is
/// never shown, so the keyboard has somewhere to be.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct SidebarSearchViewTests {
    @Test func deletingAllTheWordsKeepsSearchWhileTheFieldHasTheKeyboard() async throws {
        try await DemoAccount.with { session in
            let sidebar = try ShownSidebar(session)
            try sidebar.type("a")
            #expect(sidebar.showsResults)

            try sidebar.deleteAll()
            #expect(sidebar.field.stringValue.isEmpty)
            #expect(sidebar.showsResults, "deleting the words ended search")
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
            #expect(!sidebar.showsResults)
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

    @Test func theFieldsClearButtonEndsSearch() async throws {
        try await DemoAccount.with { session in
            let sidebar = try ShownSidebar(session)
            try sidebar.type("a")
            #expect(sidebar.showsResults)

            try #require((sidebar.field.cell as? NSSearchFieldCell)?.cancelButtonCell).performClick(sidebar.field)
            #expect(sidebar.field.stringValue.isEmpty)
            #expect(!sidebar.showsResults)
            #expect(!sidebar.fieldHasKeyboard)
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
            #expect(!sidebar.showsResults)
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
            #expect(!sidebar.showsResults)
            #expect(sidebar.field.stringValue.isEmpty)
        }
    }

    @Test func searchHasNoCloseButtonBesideTheField() async throws {
        try await DemoAccount.with { session in
            let sidebar = try ShownSidebar(session)
            try sidebar.type("a")
            sidebar.controller.view.layoutSubtreeIfNeeded()

            // the field keeps the sidebar's width; nothing stands beside it.
            #expect(sidebar.field.frame.maxX == sidebar.controller.view.bounds.maxX - 10)
            let besideField = sidebar.controller.view.subviews.filter {
                $0 !== sidebar.field && $0.frame.minX >= sidebar.field.frame.minX && $0.frame.intersects(sidebar.field.frame)
            }
            #expect(besideField.isEmpty, "\(besideField)")
        }
    }
}

/// The sidebar's controller, its view laid out at a sidebar's size in a window that is never
/// shown, beside a text view standing for the rest of the window (a chat's composer), with its
/// search field and what shows under it.
@MainActor
private struct ShownSidebar {
    let controller: SidebarController
    let window: NSWindow
    let field: NSSearchField
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
    }

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
