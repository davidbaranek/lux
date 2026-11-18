import LuxCore
import Testing
import UIKit
@testable import Lux

/// A chat's screen over a demo account of its own, seen through its collection view: where the
/// chat opens. No window: the test reads the scroll view's place, not what is drawn.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct ThreadViewTests {
    @Test func aReadChatOpensAtItsNewestMessage() async throws {
        try await DemoAccount.with(rooms: 10, messagesPerRoom: 60) { session in
            let row = try await readChat(in: session)
            let chat = try ShownChat(ThreadViewController(session: session, row: row, theme: .neutral, list: nil))
            // the newest message all on screen: nothing below it.
            try await chat.changes.until { chat.isShown(chat.newest) }
        }
    }

    @Test func aChatOpenedAtAMessageLandsOnIt() async throws {
        try await DemoAccount.with(rooms: 10, messagesPerRoom: 60) { session in
            let row = try await readChat(in: session)
            // the demo's events are its messages' ids: the chat's sixth message, screens above its newest.
            let target = "\(row.id)/5"
            let controller = ThreadViewController(session: session, row: row, theme: .neutral, list: nil,
                                                  focus: MessageLink(roomId: row.id, eventId: target))
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

/// A chat's controller, its view loaded and laid out at a phone's size, and the announcements of
/// its list: each new content size or place wakes the test.
@MainActor
private struct ShownChat {
    let controller: ThreadViewController
    let collectionView: UICollectionView
    let changes = Changes()
    private let observations: [NSKeyValueObservation]

    init(_ controller: ThreadViewController) throws {
        self.controller = controller
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let collectionView = try #require(controller.view.subviews.lazy.compactMap { $0 as? UICollectionView }.first)
        self.collectionView = collectionView
        let changes = changes
        observations = [
            collectionView.observe(\.contentSize) { _, _ in MainActor.assumeIsolated { changes.send() } },
            collectionView.observe(\.contentOffset) { _, _ in MainActor.assumeIsolated { changes.send() } },
        ]
        // the width is known: the messages are measured for it, then shown.
        controller.view.layoutIfNeeded()
    }

    /// The last row's index; -1 before any.
    var newest: Int { collectionView.numberOfSections == 0 ? -1 : collectionView.numberOfItems(inSection: 0) - 1 }

    /// What the list shows, between the bars over and under it.
    private var seen: ClosedRange<CGFloat> {
        let inset = collectionView.adjustedContentInset, offset = collectionView.contentOffset.y
        return offset + inset.top ... offset + collectionView.bounds.height - inset.bottom
    }

    private func frame(of item: Int) -> CGRect? {
        guard item >= 0, item <= newest else { return nil }
        return collectionView.layoutAttributesForItem(at: IndexPath(item: item, section: 0))?.frame
    }

    /// The row is all on screen.
    func isShown(_ item: Int) -> Bool {
        frame(of: item).map { seen.contains($0.minY) && seen.contains($0.maxY) } ?? false
    }

    /// The row's middle is in the middle third of what the list shows, where a jump brings it.
    func isCentred(_ item: Int) -> Bool {
        guard let frame = frame(of: item) else { return false }
        let seen = seen, third = (seen.upperBound - seen.lowerBound) / 3
        return (seen.lowerBound + third ... seen.upperBound - third).contains(frame.midY)
    }
}
