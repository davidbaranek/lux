import AppKit
import LuxCore
import Testing
@testable import Lux

/// A chat's pane over a demo account of its own, seen through its table: where the chat opens.
/// No window: the test reads the clip view's place, not what is drawn.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct ThreadViewTests {
    @Test func aReadChatOpensAtItsNewestMessage() async throws {
        try await DemoAccount.with(rooms: 10, messagesPerRoom: 60) { session in
            let row = try await readChat(in: session)
            let chat = try ShownChat(ThreadController(session: session, row: row, theme: .neutral))
            // the newest message all on screen: nothing below it.
            try await chat.changes.until { chat.isShown(chat.newest) }
        }
    }

    @Test func aChatOpenedAtAMessageLandsOnIt() async throws {
        try await DemoAccount.with(rooms: 10, messagesPerRoom: 60) { session in
            let row = try await readChat(in: session)
            // the demo's events are its messages' ids: the chat's sixth message, screens above its newest.
            let target = "\(row.id)/5"
            let controller = ThreadController(session: session, row: row, theme: .neutral, focus: MessageLink(roomId: row.id, eventId: target))
            let chat = try ShownChat(controller)
            try await chat.changes.until {
                controller.model.messages.firstIndex { $0.eventId == target }.map(chat.isCentred) == true
            }
        }
    }

    /// A chat of the demo with no unread message: it opens at its newest.
    private func readChat(in session: Session) async throws -> ChatRow {
        let list = ChatListModel(session: session)
        let changes = list.changes()
        list.reload()
        try await changes.until { list.rows.contains { !$0.isUnread && !$0.isMerged && !$0.isGroup } }
        return try #require(list.rows.first { !$0.isUnread && !$0.isMerged && !$0.isGroup })
    }
}

/// A chat's controller, its view loaded and laid out at a pane's size, and the announcements of
/// its list: each new place of the clip view, or size of the table, wakes the test.
@MainActor
private final class ShownChat {
    let controller: ThreadController
    let table: NSTableView
    let clip: NSClipView
    let changes: Changes
    private let observations: [any NSObjectProtocol]

    init(_ controller: ThreadController) throws {
        self.controller = controller
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 700, height: 800)
        let scroll = try #require(controller.view.subviews.lazy.compactMap { $0 as? NSScrollView }.first)
        let table = try #require(scroll.documentView as? NSTableView), clip = scroll.contentView
        self.table = table
        self.clip = clip
        clip.postsBoundsChangedNotifications = true
        table.postsFrameChangedNotifications = true
        let changes = Changes()
        self.changes = changes
        observations = [
            NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { _ in
                MainActor.assumeIsolated { changes.send() }
            },
            NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: table, queue: .main) { _ in
                MainActor.assumeIsolated { changes.send() }
            },
        ]
        // the width is known: the messages are measured for it, then shown.
        controller.view.layoutSubtreeIfNeeded()
    }

    isolated deinit {
        for observation in observations { NotificationCenter.default.removeObserver(observation) }
    }

    /// The last row's index; -1 before any.
    var newest: Int { table.numberOfRows - 1 }

    /// What the table shows, between the insets over and under it.
    var seen: NSRect {
        let insets = clip.contentInsets
        return NSRect(x: 0, y: clip.bounds.minY + insets.top, width: clip.bounds.width,
                      height: clip.bounds.height - insets.top - insets.bottom)
    }

    /// The row is all on screen.
    func isShown(_ row: Int) -> Bool {
        guard row >= 0, row <= newest else { return false }
        let rect = table.rect(ofRow: row)
        return rect.minY >= seen.minY && rect.maxY <= seen.maxY
    }

    /// The row's middle is in the middle third of what the table shows, where a jump brings it.
    func isCentred(_ row: Int) -> Bool {
        guard row >= 0, row <= newest else { return false }
        let seen = seen, third = seen.height / 3
        return (seen.minY + third ... seen.maxY - third).contains(table.rect(ofRow: row).midY)
    }
}
