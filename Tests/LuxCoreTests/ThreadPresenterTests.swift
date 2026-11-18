import CoreGraphics
import Foundation
import Testing
@testable import LuxCore

/// A list 600 points tall, a 100-point bar above and a 50-point composer below: 450 seen.
private func geometry(offset: CGFloat, content: CGFloat = 10_000) -> ScrollGeometry {
    ScrollGeometry(offset: offset, height: 600, contentHeight: content, top: 100, bottom: 50)
}

struct ScrollGeometryTests {
    @Test func theNewestMessageIsWithinFortyPointsOfTheEnd() {
        // the end: the content's last point over the composer.
        #expect(geometry(offset: 9_450).isAtBottom)
        #expect(geometry(offset: 9_411).isAtBottom)
        #expect(!geometry(offset: 9_409).isAtBottom)
        #expect(geometry(offset: 9_450).fromBottom == 0)
    }

    @Test func theWayDownShowsAScreenAboveTheEnd() {
        #expect(!geometry(offset: 8_850).isScreenAboveBottom)
        #expect(geometry(offset: 8_849).isScreenAboveBottom)
    }

    @Test func olderMessagesAreAskedForThreeScreensBeforeTheTop() {
        #expect(geometry(offset: 1_799).nearsTop)
        #expect(!geometry(offset: 1_800).nearsTop)
    }

    @Test func aRowIsAboveOnceItEndsUnderTheBar() {
        let shown = geometry(offset: 1_000)
        #expect(shown.isAbove(1_100))
        #expect(!shown.isAbove(1_101))
    }

    @Test func aChatOpensAtItsFirstUnreadMessageOnlyWithMoreThanAScreenAfterIt() {
        #expect(geometry(offset: 0).opening(atUnread: 5_000) == 4_900)
        // 450 seen: 400 after the marker fit, the chat opens at its end.
        #expect(geometry(offset: 0).opening(atUnread: 9_600) == nil)
    }

    @Test func aShortChatCannotScrollPastItsTop() {
        let short = geometry(offset: -100, content: 300)
        #expect(short.range == -100 ... -100)
    }
}

struct JumpPlanTests {
    @Test func aNearMessageGlidesToTheMiddleOfWhatIsSeen() {
        // the row's middle at 1_250; seen from the offset + 100, 450 tall: its middle at offset + 325.
        let plan = JumpPlan(toRowFrom: 1_200, to: 1_300, in: geometry(offset: 1_000))
        #expect(plan == JumpPlan(start: nil, end: 925))
        #expect(!plan.arrived(from: 1_000))
    }

    @Test func aFarMessageIsFirstBroughtAScreenAway() {
        let up = JumpPlan(toRowFrom: 1_200, to: 1_300, in: geometry(offset: 9_000))
        #expect(up == JumpPlan(start: 925 + 450, end: 925))
        let down = JumpPlan(toRowFrom: 5_200, to: 5_300, in: geometry(offset: 0))
        #expect(down == JumpPlan(start: 4_925 - 450, end: 4_925))
    }

    @Test func theGlideStopsWhereTheContentEnds() {
        #expect(JumpPlan(toRowFrom: 0, to: 40, in: geometry(offset: 300)).end == -100)
        #expect(JumpPlan(toRowFrom: 9_960, to: 10_000, in: geometry(offset: 9_200)).end == 9_450)
    }

    @Test func aMessageAlreadyInTheMiddleOnlyFlashes() {
        let plan = JumpPlan(toRowFrom: 1_200, to: 1_300, in: geometry(offset: 925.5))
        #expect(plan.arrived(from: 925.5))
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct TaskBagTests {
    @Test func aTaskEndsWithItsBag() async throws {
        let ended = Changes()
        var cancelled = false
        var bag: TaskBag? = TaskBag()
        bag?.run {
            do { try await Task.sleep(for: .seconds(30)) } catch {
                cancelled = true
                ended.send()
            }
        }
        bag = nil
        try await ended.until { cancelled }
    }

    @Test func aNewerTaskOfTheSameKeyCancelsTheOlder() async throws {
        let bag = TaskBag()
        let changes = Changes()
        var olderCancelled = false
        var newerRan = false
        bag.run("jump") {
            do { try await Task.sleep(for: .seconds(30)) } catch is CancellationError {
                olderCancelled = true
                changes.send()
            }
        }
        bag.run("jump") {
            newerRan = true
            changes.send()
        }
        try await changes.until { olderCancelled && newerRan }
    }
}

/// A screen of rows stacked by their measured heights, scrolled where the presenter asks.
@MainActor
private final class StackedScreen: ThreadScreen {
    var shown: [[MessageItem]] = []
    var order: [String] = []
    var heights: [String: CGFloat] = [:]
    var draft: String?
    var offset: CGFloat = 0
    var glides: [CGFloat] = []
    var flashed: [String] = []
    var openedThreads: [(MatrixThread, MessageLink?)] = []
    /// The presenter it shows for: told after each update, as the apps' screens do.
    weak var presenter: ThreadPresenter?
    let changes = Changes()

    func show(_ messages: [MessageItem], layouts: [String: MessageLayout], changed: [String]) {
        shown.append(messages)
        order = messages.map(\.id)
        heights = layouts.mapValues(\.height)
        presenter?.jumpIfShown()
        changes.send()
    }

    var readingRow: String? { order.first { (rowSpan(of: $0)?.maxY ?? 0) > offset } }

    func openThread(_ thread: MatrixThread, at message: MessageLink?) {
        openedThreads.append((thread, message))
        changes.send()
    }

    func showDraft(_ text: String) {
        draft = text
        changes.send()
    }

    var scrollGeometry: ScrollGeometry {
        ScrollGeometry(offset: offset, height: 600, contentHeight: order.reduce(0) { $0 + (heights[$1] ?? 0) }, top: 0, bottom: 0)
    }

    func rowSpan(of id: String) -> (minY: CGFloat, maxY: CGFloat)? {
        guard let index = order.firstIndex(of: id) else { return nil }
        let minY = order[..<index].reduce(0) { $0 + (heights[$1] ?? 0) }
        return (minY, minY + (heights[id] ?? 0))
    }

    func scrollList(to offset: CGFloat, animated: Bool) {
        if animated { glides.append(offset) } else { self.offset = offset }
    }

    func flash(_ id: String) { flashed.append(id) }
}

/// Every character 8 x 16 points.
private struct GridMeasure: TextMeasuring {
    func size(of text: String, role: TextRole, width: CGFloat) -> CGSize {
        let perLine = max(Int(width / 8), 1)
        return CGSize(width: CGFloat(min(text.count, perLine) * 8), height: CGFloat(max((text.count + perLine - 1) / perLine, 1) * 16))
    }
}

/// The chat's screen without its views, over the demo account.
@MainActor
@Suite(.closesDemoSessions, .timeLimit(.minutes(1)))
struct ThreadPresenterTests {
    private let session: Session

    init() throws {
        session = try DemoSessions.open(rooms: 10, messagesPerRoom: 60)
    }

    private func opened(at focus: ((ChatRow) -> MessageLink)? = nil) async throws -> (ThreadPresenter, StackedScreen) {
        let rows = try await session.account.value.chats()
        let row = try #require(rows.first { !$0.isMerged })
        let presenter = ThreadPresenter(session: session, row: row, focus: focus?(row), removeDelivered: { _ in })
        let screen = StackedScreen()
        presenter.screen = screen
        screen.presenter = presenter
        presenter.measure(with: GridMeasure())
        presenter.resize(to: 390)
        presenter.start()
        return (presenter, screen)
    }

    @Test func theChatOpensWithItsDraftAndItsMessagesMeasured() async throws {
        let (presenter, screen) = try await opened()
        try await screen.changes.until { screen.draft != nil && !(screen.shown.last ?? []).isEmpty }
        #expect(screen.draft == "")
        let shown = try #require(screen.shown.last)
        #expect(shown.map(\.id) == presenter.model.messages.map(\.id))
        #expect(shown.allSatisfy { (screen.heights[$0.id] ?? 0) > 0 })
    }

    @Test func nothingIsMeasuredBeforeTheWidthIsKnown() async throws {
        let rows = try await session.account.value.chats()
        let presenter = ThreadPresenter(session: session, row: rows[0], removeDelivered: { _ in })
        let screen = StackedScreen()
        presenter.screen = screen
        presenter.measure(with: GridMeasure())
        let changes = presenter.model.changes()
        await presenter.model.start()
        try await changes.until { presenter.model.hasLoaded }
        presenter.show(presenter.model.messages)
        #expect(screen.shown.isEmpty)
    }

    @Test func onScreenTheChatGetsNoNotificationsAndOffScreenItDoesAgain() async throws {
        let (presenter, _) = try await opened()
        let rooms = Set([presenter.model.chatId] + presenter.model.rooms.map(\.id))
        presenter.appeared()
        #expect(session.roomsOnScreen == rooms)
        presenter.disappeared(draft: "")
        #expect(session.roomsOnScreen.isEmpty)
    }

    @Test func aThreadAndItsChatAreOnScreenTogether() async throws {
        let (presenter, screen) = try await opened()
        try await screen.changes.until { !(screen.shown.last ?? []).isEmpty }
        let root = try #require(presenter.model.messages.last { !$0.eventId.isEmpty })
        let rows = try await session.account.value.chats()
        let row = try #require(rows.first { $0.id == presenter.model.chatId })
        let thread = ThreadPresenter(session: session, row: row, thread: MatrixThread(roomId: root.roomId, rootEventId: root.eventId),
                                     removeDelivered: { _ in })
        presenter.appeared()
        thread.appeared()
        #expect(session.roomsOnScreen.contains(presenter.model.chatId))
        #expect(session.threadsOnScreen == [root.eventId])
        thread.disappeared(draft: "")
        #expect(session.threadsOnScreen.isEmpty)
        #expect(session.roomsOnScreen.contains(presenter.model.chatId))
        presenter.disappeared(draft: "")
    }

    @Test func theWayUpGlidesToTheFirstUnreadMessageAndFlashesIt() async throws {
        let (presenter, screen) = try await opened()
        try await screen.changes.until { presenter.model.firstUnreadId != nil && (screen.shown.last ?? []).count > 10 }
        presenter.didShowFirst()
        let unread = try #require(presenter.model.firstUnreadId)
        screen.offset = 0
        presenter.jumpToFirstUnread()
        #expect(presenter.isJumping)
        let span = try #require(screen.rowSpan(of: unread))
        let plan = JumpPlan(toRowFrom: span.minY, to: span.maxY, in: ScrollGeometry(offset: 0, height: 600,
                            contentHeight: screen.scrollGeometry.contentHeight, top: 0, bottom: 0))
        #expect(screen.glides == [plan.end])
        presenter.didEndScrolling()
        #expect(!presenter.isJumping)
        #expect(screen.flashed == [unread])
    }

    @Test func aLaterUpdateWinsOverAnOlderOneStillMeasuring() async throws {
        let (presenter, screen) = try await opened()
        try await screen.changes.until { !(screen.shown.last ?? []).isEmpty }
        let count = screen.shown.count
        let all = presenter.model.messages
        presenter.show(Array(all.prefix(3)))
        presenter.show(all)
        try await screen.changes.until { screen.shown.count > count }
        #expect(screen.shown.count == count + 1)
        #expect(screen.shown.last?.map(\.id) == all.map(\.id))
    }

    @Test func aChatOpenedAtAMessageGlidesToItAndFlashesIt() async throws {
        // the demo's events are its messages' ids: the chat's sixth message.
        let (presenter, screen) = try await opened { row in MessageLink(roomId: row.id, eventId: "\(row.id)/5") }
        try await screen.changes.until { presenter.isJumping }
        presenter.didEndScrolling()
        let target = try #require(screen.flashed.first)
        #expect(presenter.model.messages.first { $0.id == target }?.eventId.hasSuffix("/5") == true)
        #expect(presenter.model.isLive)
    }

    @Test func aMessageTheServerDoesNotHaveIsSaidSoAndTheChatStaysLive() async throws {
        let (presenter, screen) = try await opened()
        try await screen.changes.until { !(screen.shown.last ?? []).isEmpty }
        var failure: Error?
        presenter.model.onError = { failure = $0; screen.changes.send() }
        presenter.jump(toMessage: MessageLink(roomId: presenter.model.chatId, eventId: "$gone"))
        try await screen.changes.until { failure != nil }
        #expect(failure as? JumpError == .notFound)
        #expect(presenter.model.isLive)
    }

    @Test func jumpToBottomOnTheLiveRowsLeavesTheScrollToTheScreen() async throws {
        let (presenter, screen) = try await opened()
        try await screen.changes.until { !(screen.shown.last ?? []).isEmpty }
        #expect(!presenter.returnToLive())
    }

    @Test func aMessageFarBackShowsAmongItsNeighboursUntilJumpToBottom() async throws {
        // 400 messages a chat: the device's live timeline holds the newest 200.
        let long = try DemoSessions.open(rooms: 3, messagesPerRoom: 400)
        let rows = try await long.account.value.chats()
        let row = try #require(rows.first { !$0.isMerged })
        let presenter = ThreadPresenter(session: long, row: row, focus: MessageLink(roomId: row.id, eventId: "\(row.id)/10"),
                                        removeDelivered: { _ in })
        let screen = StackedScreen()
        presenter.screen = screen
        screen.presenter = presenter
        presenter.measure(with: GridMeasure())
        presenter.resize(to: 390)
        presenter.start()
        let changes = presenter.model.changes()
        try await changes.until { !presenter.model.isLive && presenter.model.messages.contains { $0.eventId == "\(row.id)/10" } }
        presenter.didShowFirst()
        #expect(presenter.returnToLive())
        try await changes.until { presenter.model.isLive }
        #expect(presenter.model.messages.last?.eventId == "\(row.id)/399")
    }
}

