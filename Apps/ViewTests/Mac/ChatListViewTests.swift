import AppKit
import LuxCore
import Testing
@testable import Lux

/// The sidebar's chat list over a demo account of its own, seen through its table: the rows the
/// model gives, and how an update reaches them (`AGENTS.md`). No window: nothing here depends on
/// drawing, animation or focus.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct ChatListViewTests {
    @Test func theListShowsTheModelsChatsInItsOrder() async throws {
        try await DemoAccount.with { session in
            let list = try ShownChatList(session)
            try await list.changes.until { !list.model.rows.isEmpty }
            let snapshot = list.dataSource.snapshot()
            let sections = list.model.sections
            #expect(snapshot.sectionIdentifiers == sections.map(\.id))
            for section in sections {
                let items = snapshot.itemIdentifiers(inSection: section.id)
                switch section.style {
                // the pinned chats: one row holds their grid.
                case .grid: #expect(items.count == 1)
                case .list: #expect(items == section.rows.map(\.id))
                }
            }
        }
    }

    @Test func anArchivedChatLeavesTheListAndNoOtherRowDoes() async throws {
        try await DemoAccount.with { session in
            let list = try ShownChatList(session)
            let archived = try await list.firstListedChat()
            let before = list.dataSource.snapshot().itemIdentifiers
            list.model.change(archived, .archive)
            try await list.changes.until { !list.dataSource.snapshot().itemIdentifiers.contains(archived) }
            #expect(list.dataSource.snapshot().itemIdentifiers == before.filter { $0 != archived })
        }
    }

    @Test func aChatMarkedUnreadChangesInItsOwnRowAndTheRowsStay() async throws {
        try await DemoAccount.with { session in
            let list = try ShownChatList(session)
            _ = try await list.firstListedChat()
            let shown = list.shownCells()
            let marked = try #require(shown.first { shown in
                list.model.rows.first { $0.id == shown.id }?.isUnread == false
            }, "no read chat on screen")
            let before = list.dataSource.snapshot().itemIdentifiers
            list.model.setUnread(marked.id, true)
            try await list.changes.until { list.model.rows.first { $0.id == marked.id }?.isMarkedUnread == true }
            #expect(list.dataSource.snapshot().itemIdentifiers == before)
            // shown again in place, never reloaded: the same views, at once, the marked one saying so.
            #expect(list.table.view(atColumn: 0, row: marked.row, makeIfNecessary: false) === marked.cell)
            #expect(marked.cell.accessibilityLabel()?.contains(String(localized: "unread")) == true)
            for cell in shown where cell.row != marked.row {
                #expect(list.table.view(atColumn: 0, row: cell.row, makeIfNecessary: false) === cell.cell,
                        "the view of row \(cell.row) was replaced")
            }
        }
    }

    /// The activity bubble sits over the top of the list. Gone, it takes no click: AppKit
    /// hit-tests a view whatever its alpha, so one only faded out took the top row's clicks.
    @Test func aClickWhereTheGoneActivityBubbleWasReachesTheChatUnderIt() async throws {
        try await DemoAccount.with { session in
            let list = try ShownChatList(session)
            // in a window that is never shown, which lays the list out as the bubble's room changes.
            let window = NSWindow(contentRect: list.controller.view.frame, styleMask: [.titled], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.contentView?.addSubview(list.controller.view)
            let first = try await list.firstListedChat()

            // the account loaded: the bubble gone (as it went, or as it began), the list slid back
            // up under its place.
            let bubble = try #require(list.controller.view.subviews.lazy.compactMap { $0 as? LoadingBubble }.first)
            let scroll = try #require(list.table.enclosingScrollView)
            let moved = list.changes
            let observations = [bubble.observe(\.isHidden) { _, _ in MainActor.assumeIsolated { moved.send() } },
                                scroll.observe(\.frame) { _, _ in MainActor.assumeIsolated { moved.send() } }]
            defer { observations.forEach { $0.invalidate() } }
            try await moved.until {
                list.model.loadState == .done && bubble.isHidden && scroll.frame.maxY == list.controller.view.bounds.maxY
            }

            // the first chat at the list's top, under the bubble's place.
            let row = try #require(list.dataSource.row(forItemIdentifier: first))
            let clip = scroll.contentView
            clip.scroll(to: NSPoint(x: 0, y: list.table.rect(ofRow: row).minY - clip.contentInsets.top))
            list.controller.view.layoutSubtreeIfNeeded()
            let point = NSPoint(x: bubble.frame.midX, y: bubble.frame.midY)
            try #require(list.table.row(at: list.table.convert(point, from: list.controller.view)) == row,
                         "the first chat is not under the bubble's place")

            // where the window sends the click: a view of the first chat's row, which passes the
            // press on to the table.
            let hit = try #require(list.controller.view.hitTest(point))
            #expect(hit.isDescendant(of: list.table), "\(hit) takes the click over the first chat")
            #expect(list.table.row(for: hit) == row)
        }
    }
}

/// A chat list's controller, its view loaded and laid out at a sidebar's size, with what the
/// test reads of it.
@MainActor
private struct ShownChatList {
    let controller: ChatListController
    let model: ChatListModel
    let table: NSTableView
    let dataSource: NSTableViewDiffableDataSource<String, String>
    let changes: Changes

    init(_ session: Session) throws {
        model = ChatListModel(session: session)
        controller = ChatListController(session: session, model: model)
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 300, height: 900)
        let scroll = try #require(controller.view.subviews.lazy.compactMap { $0 as? NSScrollView }.first)
        table = try #require(scroll.documentView as? NSTableView)
        dataSource = try #require(table.dataSource as? NSTableViewDiffableDataSource<String, String>)
        changes = model.changes()
    }

    /// The first chat of the list's own section (not the pinned grid), once the chats came and
    /// their rows are laid out.
    func firstListedChat() async throws -> String {
        try await changes.until { model.sections.contains { $0.style == .list && !$0.rows.isEmpty } }
        controller.view.layoutSubtreeIfNeeded()
        return try #require(model.sections.first { $0.style == .list }?.rows.first?.id)
    }

    /// The chats' views on screen, by row.
    func shownCells() -> [(row: Int, id: String, cell: NSView)] {
        let rows = table.rows(in: table.visibleRect)
        return (rows.lowerBound ..< rows.upperBound).compactMap { row in
            guard let id = dataSource.itemIdentifier(forRow: row), model.rows.contains(where: { $0.id == id }),
                  let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) else { return nil }
            return (row, id, cell)
        }
    }
}
