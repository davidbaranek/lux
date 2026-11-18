import Foundation
import Testing
@testable import LuxCore

/// A screen that keeps what the presenter told it.
@MainActor
private final class RecordingListScreen: ChatListScreen {
    var updates: [ChatListUpdate] = []
    var activities: [(ListActivity?, Bool)] = []
    let changes = Changes()

    func show(_ update: ChatListUpdate) {
        updates.append(update)
        changes.send()
    }

    func showActivity(_ activity: ListActivity?, toggles: Bool) {
        activities.append((activity, toggles))
        changes.send()
    }

    func runBenchmark(_ rows: [ChatRow]) {}
}

/// The chat list's screen without its views, over the demo account.
@MainActor
@Suite(.closesDemoSessions, .timeLimit(.minutes(1)))
struct ChatListPresenterTests {
    private let session = DemoSessions.open(rooms: 40, messagesPerRoom: 5)

    private func started() -> (ChatListPresenter, RecordingListScreen) {
        let presenter = ChatListPresenter(session: session, model: ChatListModel(session: session))
        let screen = RecordingListScreen()
        presenter.screen = screen
        presenter.start()
        return (presenter, screen)
    }

    @Test func theFirstChatsComeFirstWithTheInboxsPinnedGridAndTitles() async throws {
        let (presenter, screen) = started()
        try await screen.changes.until { !screen.updates.isEmpty }
        let first = try #require(screen.updates.first)
        #expect(presenter.model.place == .inbox)
        #expect(first.isFirst)
        #expect(!first.isNewPlace)
        #expect(first.pinned.map(\.id) == ["!room0:demo", "!room1:demo", "!room2:demo"])
        #expect(first.gridSections == Set(first.sections.filter { $0.style == .grid }.map(\.id)))
        #expect(screen.updates.dropFirst().allSatisfy { !$0.isFirst })
    }

    @Test func anotherPlaceReplacesTheListAndThenChangesRowByRow() async throws {
        let (presenter, screen) = started()
        try await screen.changes.until { !screen.updates.isEmpty }
        presenter.model.place = .network("signal")
        try await screen.changes.until { screen.updates.last?.sections.flatMap(\.rows).allSatisfy { $0.network == "signal" } == true }
        let arrived = screen.updates.firstIndex { $0.isNewPlace }
        #expect(arrived != nil)
        #expect(screen.updates.filter(\.isNewPlace).count == 1)
    }

    @Test func theBubbleShowsWhileTheListLoadsAndGoesOnceItIsDone() async throws {
        let (presenter, screen) = started()
        // the screen is told what the bubble says as soon as it is there.
        #expect(screen.activities.first?.1 == true)
        try await screen.changes.until { presenter.model.loadState == .done && presenter.activity == nil }
        #expect(screen.activities.last.map { $0.0 == nil && $0.1 } == true)
    }

    @Test func aRoomsChatIsFoundOnceTheListHasIt() async {
        let model = ChatListModel(session: session)
        let row = await model.chat(ofRoom: "!room18:demo")
        // a merged room opens as its merged chat.
        #expect(row?.rooms.map(\.id) == ["!room4:demo", "!room18:demo"])
    }

    @Test func anUnknownRoomGivesUpAtTheLimit() async {
        let model = ChatListModel(session: session)
        let start = ContinuousClock.now
        let row = await model.chat(ofRoom: "!nowhere:demo", within: .milliseconds(300))
        #expect(row == nil)
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    @Test func aCancelledWaitEndsAtOnce() async {
        let model = ChatListModel(session: session)
        let waiting = Task { await model.chat(ofRoom: "!nowhere:demo", within: .seconds(60)) }
        waiting.cancel()
        let start = ContinuousClock.now
        #expect(await waiting.value == nil)
        #expect(ContinuousClock.now - start < .seconds(3))
    }
}
