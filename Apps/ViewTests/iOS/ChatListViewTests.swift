import LuxCore
import Testing
import UIKit
@testable import Lux

/// The chat list's screen over a demo account of its own, seen through its collection view: the
/// rows the model gives, and how an update reaches them (`AGENTS.md`). No window: nothing here
/// depends on drawing, animation or focus.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct ChatListViewTests {
    @Test func theListShowsTheModelsChatsInItsOrder() async throws {
        try await DemoAccount.with { session in
            let screen = try ShownChatList(session)
            try await screen.changes.until { !screen.model.rows.isEmpty }
            let snapshot = screen.dataSource.snapshot()
            let sections = screen.model.sections
            #expect(snapshot.sectionIdentifiers == sections.map(\.id))
            for section in sections {
                let items = snapshot.itemIdentifiers(inSection: section.id)
                switch section.style {
                // the pinned chats: a cell each in the grid.
                case .grid: #expect(items.count == section.rows.count)
                case .list: #expect(items == section.rows.map(\.id))
                }
            }
        }
    }

    @Test func anArchivedChatLeavesTheListAndNoOtherRowDoes() async throws {
        try await DemoAccount.with { session in
            let screen = try ShownChatList(session)
            let archived = try await screen.firstListedChat()
            let before = screen.dataSource.snapshot().itemIdentifiers
            screen.model.change(archived, .archive)
            try await screen.changes.until { !screen.dataSource.snapshot().itemIdentifiers.contains(archived) }
            #expect(screen.dataSource.snapshot().itemIdentifiers == before.filter { $0 != archived })
        }
    }

    @Test func aChatMarkedUnreadChangesInItsOwnCellAndTheRowsStay() async throws {
        try await DemoAccount.with { session in
            let screen = try ShownChatList(session)
            _ = try await screen.firstListedChat()
            let shown = screen.shownCells()
            let marked = try #require(shown.first { screen.row(in: $0.cell)?.isUnread == false }, "no read chat on screen")
            let markedId = try #require(screen.row(in: marked.cell)?.id)
            let before = screen.dataSource.snapshot().itemIdentifiers
            screen.model.setUnread(markedId, true)
            try await screen.changes.until { screen.model.rows.first { $0.id == markedId }?.isMarkedUnread == true }
            #expect(screen.dataSource.snapshot().itemIdentifiers == before)
            // reconfigured in place, never reloaded: the same cells, at once, the marked one showing it.
            #expect(screen.collectionView.cellForItem(at: marked.path) === marked.cell)
            #expect(screen.row(in: marked.cell)?.isMarkedUnread == true)
            for (path, cell) in shown where path != marked.path {
                #expect(screen.collectionView.cellForItem(at: path) === cell, "the cell at \(path) was replaced")
            }
        }
    }
}

/// A chat list's screen, its view loaded and laid out at a phone's size, with what the test
/// reads of it.
@MainActor
private struct ShownChatList {
    let controller: ChatListViewController
    let collectionView: UICollectionView
    let dataSource: UICollectionViewDiffableDataSource<String, String>
    let changes: Changes
    var model: ChatListModel { controller.model }

    init(_ session: Session) throws {
        controller = ChatListViewController(session: session) {}
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        collectionView = try #require(controller.view.subviews.lazy.compactMap { $0 as? UICollectionView }.first)
        dataSource = try #require(collectionView.dataSource as? UICollectionViewDiffableDataSource<String, String>)
        changes = controller.model.changes()
    }

    /// The first chat of the list's own section (not the pinned grid), once the chats came and
    /// their cells are laid out.
    func firstListedChat() async throws -> String {
        try await changes.until { model.sections.contains { $0.style == .list && !$0.rows.isEmpty } }
        controller.view.layoutIfNeeded()
        return try #require(model.sections.first { $0.style == .list }?.rows.first?.id)
    }

    /// The cells on screen, by where they are.
    func shownCells() -> [(path: IndexPath, cell: UICollectionViewCell)] {
        collectionView.indexPathsForVisibleItems.sorted().compactMap { path in
            collectionView.cellForItem(at: path).map { (path, $0) }
        }
    }

    /// The chat a list cell shows.
    func row(in cell: UICollectionViewCell) -> ChatRow? {
        (cell.contentConfiguration as? ChatRowConfiguration)?.row
    }
}
