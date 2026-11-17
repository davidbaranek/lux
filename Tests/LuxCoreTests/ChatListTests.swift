import Foundation
import Testing
@testable import LuxCore

/// The chat list over the Rust core's demo account: the view model composes, the model applies.
@MainActor
@Suite(.closesDemoSessions)
struct ChatListModelTests {
    private let session = DemoSessions.open(rooms: 40, messagesPerRoom: 5)

    @Test func theInboxShowsPinnedChatsInAGridAndThePlacesWithTheirNames() async {
        let model = ChatListModel(session: session)
        let changes = model.changes()
        await changes.until { model.sections.count == 2 && !model.places.isEmpty }
        #expect(model.sections.map(\.style) == [.grid, .list])
        #expect(model.sections[0].rows.map(\.id) == ["!room0:demo", "!room1:demo", "!room2:demo"])
        #expect(model.rows.contains { $0.isMerged && $0.rooms.map(\.id) == ["!room4:demo", "!room18:demo"] })
        #expect(model.places.prefix(3).map(\.id) == [.inbox, .folder(.lowPriority), .folder(.archive)])
        #expect(model.places.contains { $0.id == .space("!space-family:demo") && $0.title == "Family" })
        #expect(model.places.contains { $0.id == .label("demo-work") && $0.title == "Work" })
        // only the top of a tree of spaces is a place.
        #expect(!model.places.contains { $0.id == .space("!space-work-design:demo") })
        #expect(model.labels.map(\.name) == ["Work"])
        await changes.until { model.loadState == .done }
    }

    @Test func aPlaceAndAFilterShowOnlyTheirChats() async {
        let model = ChatListModel(session: session)
        let changes = model.changes()
        await changes.until { !model.rows.isEmpty }
        model.place = .network("signal")
        await changes.until { !model.rows.isEmpty && model.rows.allSatisfy { $0.network == "signal" } }
        model.filter = .unread
        await changes.until { !model.rows.isEmpty && model.rows.allSatisfy(\.isUnread) }
        model.place = .requests
        await changes.until { model.rows.map(\.id) == ["!invite-1:demo", "!invite-2:demo"] }
        if case .request = model.destination(of: model.rows[0]) {} else { Issue.record("a request leads to its answer") }
    }

    @Test func aPlaceChosenBeforeTheListOpensIsTheFirstShown() async {
        let model = ChatListModel(session: session)
        let changes = model.changes()
        model.place = .network("signal")
        await changes.until { !model.rows.isEmpty }
        #expect(model.place == .network("signal"))
        #expect(model.rows.allSatisfy { $0.network == "signal" })
    }

    @Test func aLabelNamedLikeAnotherFailsInTheUsersWords() async {
        let model = ChatListModel(session: session)
        var failure: AccountFailure?
        model.onError = { failure = $0 as? AccountFailure }
        let changes = model.changes()
        await changes.until { model.labels.map(\.name) == ["Work"] }
        model.makeLabel(named: "Work", with: nil)
        await changes.until { failure != nil }
        #expect(failure == .labelNameTaken)
        #expect(failure?.isForTheUser == true)
        #expect(failure?.errorDescription == String(localized: "A label with that name already exists."))
    }

    @Test func aChatsActionMovesItAndTheUITakesOnlyTheChangedRows() async {
        let model = ChatListModel(session: session)
        var updates: [(ids: [String], changed: [String])] = []
        model.onUpdate = { sections, changed in updates.append((sections.flatMap(\.rows).map(\.id), changed)) }
        let changes = model.changes()
        await changes.until { model.rows.contains { $0.id == "!room5:demo" } }
        model.change("!room5:demo", .archive)
        await changes.until { !model.rows.contains { $0.id == "!room5:demo" } }
        model.setUnread("!room6:demo", true)
        await changes.until { model.rows.first { $0.id == "!room6:demo" }?.isMarkedUnread == true }
        #expect(updates.last?.changed == ["!room6:demo"])
        model.place = .folder(.archive)
        await changes.until { model.rows.contains { $0.id == "!room5:demo" } }
    }

    @Test func theBadgeIsTheInboxsCountWithTheChatsItCountsAndTheRoomsItDoesNot() async {
        let model = ChatListModel(session: session)
        var badge: BadgeState?
        model.onBadge = { badge = $0 }
        let changes = model.changes()
        await changes.until { model.rows.contains { $0.id == "!room5:demo" } && badge != nil }
        let inbox = model.places.first { $0.id == .inbox }?.unread
        #expect(badge?.count == inbox)
        #expect(badge?.counted.count ?? 0 >= badge?.count ?? 0)
        model.change("!room5:demo", .archive)
        await changes.until { badge?.uncounted.contains("!room5:demo") == true }
        #expect(badge?.counted.contains("!room5:demo") == false)
    }

    @Test func aHiddenPlaceSaysSoAndTheInboxNeverHides() async {
        let model = ChatListModel(session: session)
        let changes = model.changes()
        await changes.until { model.places.contains { $0.id == .network("signal") } }
        model.setHidden(.network("signal"), true)
        model.setHidden(.inbox, true)
        await changes.until { model.places.first { $0.id == .network("signal") }?.isHidden == true }
        #expect(model.places.first { $0.id == .inbox }?.isHidden == false)
        model.showAllPlaces()
        await changes.until { model.places.allSatisfy { !$0.isHidden } }
    }
}

struct ChatListBatchTests {
    private func row(_ id: String, _ preview: String = "") -> ChatRow { ChatRow(id: id, name: id, preview: preview, date: nil) }

    private func batch(sections: [ChatListBatch.Header]? = nil, _ rows: [ChatListBatch.SectionEdits]) -> ChatListBatch {
        ChatListBatch(place: .inbox, places: nil, theme: nil, sections: sections, rows: rows, saved: [:], scheduled: [:], labels: nil,
                      reminders: nil, loading: nil)
    }

    @Test func rowsMoveByTheirIdsAndOnlyThoseThatShowSomethingElseChange() {
        var sections: [ChatSection] = []
        let headers = [ChatListBatch.Header(id: "pinned", title: nil, style: .grid), ChatListBatch.Header(id: "all", title: nil, style: .list)]
        _ = sections.apply(batch(sections: headers, [.init(section: "all", edits: [.reset([row("a"), row("b"), row("c")])])]))
        #expect(sections.map(\.id) == ["pinned", "all"])
        // c moves to the top with a new message; b only moves to the pinned grid.
        let changed = sections.apply(batch([
            .init(section: "all", edits: [.remove(2), .insert(0, row("c", "new")), .remove(2)]),
            .init(section: "pinned", edits: [.pushBack(row("b"))]),
        ]))
        #expect(sections[1].rows.map(\.id) == ["c", "a"])
        #expect(sections[0].rows.map(\.id) == ["b"])
        #expect(changed == ["c"])
        // a section that goes takes its rows; one that stays keeps them.
        _ = sections.apply(batch(sections: [headers[1]], []))
        #expect(sections.map(\.id) == ["all"])
        #expect(sections[0].rows.map(\.id) == ["c", "a"])
        #expect(sections.apply(batch([.init(section: "all", edits: [.set(1, row("a", "hi"))])])) == ["a"])
    }
}

@Test func theLoadingBubbleSaysWhatTheAppIsDoing() {
    #expect(ListActivity.describe(.loading, search: nil)?.title == "Connecting…")
    #expect(ListActivity.describe(.syncing(newChats: 0), search: nil)?.title == "Updating chats")
    #expect(ListActivity.describe(.syncing(newChats: 12), search: nil)?.detail == "12 new")
    let quick = SearchIndexer.Progress(chats: 12, total: 150, deep: false, isIndexing: true, messages: 0, isFirstFill: true)
    #expect(ListActivity.describe(.done, search: quick)?.detail == "12 of 150 chats")
    // a later update (new messages after a send) runs without a bubble.
    #expect(ListActivity.describe(.done, search: SearchIndexer.Progress(chats: 0, total: 1, deep: false, isIndexing: true, messages: 0)) == nil)
    // the long read of older messages runs without a bubble.
    #expect(ListActivity.describe(.done, search: SearchIndexer.Progress(chats: 3, total: 150, deep: true, isIndexing: true, messages: 0)) == nil)
    #expect(ListActivity.describe(.done, search: nil) == nil)
}

@Test func aChatsMenuFollowsItsState() {
    var row = ChatRow(id: "!a", name: "A", preview: "", date: nil, unreadCount: 1)
    #expect(ChatChange.available(for: row) == [.read, .pin, .lowPriority, .archive, .delete])
    row.unreadCount = 0; row.isPinned = true; row.isMuted = true; row.folder = .archive
    #expect(ChatChange.available(for: row) == [.unread, .unpin, .unarchive, .delete])
}
