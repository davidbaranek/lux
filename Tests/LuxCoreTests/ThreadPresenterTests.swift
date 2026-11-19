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
    /// Where each update put the list.
    var intents: [ScrollIntent] = []
    var order: [String] = []
    var heights: [String: CGFloat] = [:]
    var draft: String?
    var offset: CGFloat = 0
    var glides: [CGFloat] = []
    var flashed: [String] = []
    var openedThreads: [(MatrixThread, MessageLink?)] = []
    /// The rows the presenter asked where they are.
    var asked: Set<String> = []
    /// The presenter it shows for: told when a glide arrives.
    weak var presenter: ThreadPresenter?
    let changes = Changes()

    func show(_ messages: [MessageItem], layouts: [String: MessageLayout], changed: [String], scroll: ScrollIntent) {
        shown.append(messages)
        intents.append(scroll)
        order = messages.map(\.id)
        heights = layouts.mapValues(\.height)
        place(scroll)
        changes.send()
    }

    /// The last glide asked for arrives: the apps' screens tell it once.
    func arrive() {
        if let end = glides.last { offset = end }
        presenter?.didEndScrolling()
    }

    /// A glide, if one was asked for, arrives; then the message flashes once nothing loads.
    func arrives() async throws {
        if !glides.isEmpty { arrive() }
        try await changes.until { !flashed.isEmpty }
    }

    /// Whether the message's row sits in the middle of the list, where a glide to it ends.
    func centres(_ id: String) -> Bool {
        guard let span = rowSpan(of: id) else { return false }
        return JumpPlan(toRowFrom: span.minY, to: span.maxY, in: scrollGeometry).arrived(from: offset)
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
        if asked.insert(id).inserted { changes.send() }
        guard let index = order.firstIndex(of: id) else { return nil }
        let minY = order[..<index].reduce(0) { $0 + (heights[$1] ?? 0) }
        return (minY, minY + (heights[id] ?? 0))
    }

    func scrollList(to offset: CGFloat, animated: Bool) {
        if animated { glides.append(offset) } else { self.offset = offset }
    }

    func highlight(_ id: String?) {
        if let id { flashed.append(id) }
        changes.send()
    }
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
        presenter.onLoading = { _ in screen.changes.send() }
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
        try await screen.changes.until {
            presenter.model.firstUnreadId != nil && (screen.shown.last ?? []).count > 10 && !presenter.model.isLoading
        }
        presenter.didShowFirst()
        let unread = try #require(presenter.model.firstUnreadId)
        screen.offset = 0
        presenter.jumpToFirstUnread()
        #expect(presenter.isJumping)
        let span = try #require(screen.rowSpan(of: unread))
        let plan = JumpPlan(toRowFrom: span.minY, to: span.maxY, in: ScrollGeometry(offset: 0, height: 600,
                            contentHeight: screen.scrollGeometry.contentHeight, top: 0, bottom: 0))
        #expect(screen.glides == [plan.end])
        screen.arrive()
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

    @Test func aChatOpenedAtAMessageBringsItToTheMiddleAndFlashesIt() async throws {
        // the demo's events are its messages' ids: the chat's sixth message.
        let (presenter, screen) = try await opened { row in MessageLink(roomId: row.id, eventId: "\(row.id)/5") }
        try await screen.changes.until { presenter.isJumping || !screen.flashed.isEmpty }
        try await screen.arrives()
        let target = try #require(screen.flashed.first)
        #expect(presenter.model.messages.first { $0.id == target }?.eventId.hasSuffix("/5") == true)
        #expect(screen.centres(target))
        #expect(presenter.model.isLive)
    }

    @Test func aJumpLandingBeforeTheFirstRowsAreShownCentresItsMessageOnceTheyAre() async throws {
        let rows = try await session.account.value.chats()
        let row = try #require(rows.first { !$0.isMerged })
        // the demo's events are its messages' ids: the chat's sixth message.
        let target = "\(row.id)/5"
        let presenter = ThreadPresenter(session: session, row: row, focus: MessageLink(roomId: row.id, eventId: target),
                                        removeDelivered: { _ in })
        let screen = StackedScreen()
        presenter.screen = screen
        screen.presenter = presenter
        presenter.onLoading = { _ in screen.changes.send() }
        presenter.measure(with: GridMeasure())
        presenter.start()
        // the jump landed and asked for its row: nothing is shown before the width is known.
        try await screen.changes.until { screen.asked.contains(target) }
        #expect(screen.shown.isEmpty)
        presenter.resize(to: 390)
        try await screen.arrives()
        #expect(screen.flashed == [target])
        #expect(!presenter.isJumping)
        #expect(screen.centres(target))
    }

    @Test func aJumpFarBackEndsWithItsMessageInTheMiddleFlashedOnceItsPagesStop() async throws {
        // 1 000 messages a chat: the device's live timeline holds the newest 200 (and a page more as it opens), the message is among a jump's rows.
        let long = try DemoSessions.open(rooms: 3, messagesPerRoom: 1_000)
        let rows = try await long.account.value.chats()
        let row = try #require(rows.first { !$0.isMerged })
        let presenter = ThreadPresenter(session: long, row: row, removeDelivered: { _ in })
        let screen = StackedScreen()
        presenter.screen = screen
        screen.presenter = presenter
        presenter.onLoading = { _ in screen.changes.send() }
        presenter.measure(with: GridMeasure())
        presenter.resize(to: 390)
        presenter.start()
        try await screen.changes.until { !(screen.shown.last ?? []).isEmpty }
        presenter.didShowFirst()
        presenter.jump(toMessage: MessageLink(roomId: row.id, eventId: "\(row.id)/10"))
        // while the jump's rows come it is put in place; a glide only when it landed on rows already in.
        try await screen.changes.until { presenter.isJumping || !screen.flashed.isEmpty }
        try await screen.arrives()
        let target = try #require(screen.flashed.first)
        #expect(presenter.model.messages.first { $0.id == target }?.eventId == "\(row.id)/10")
        #expect(!presenter.model.isLoading)
        #expect(!presenter.isJumping)
        #expect(screen.centres(target))
    }

    @Test func anUpdateDuringTheGlidePutsTheMessageInTheMiddleAtOnceAndFlashesIt() async throws {
        let (presenter, screen) = try await opened()
        try await screen.changes.until { (screen.shown.last ?? []).count > 20 && !presenter.model.isLoading }
        presenter.didShowFirst()
        let all = presenter.model.messages
        let message = all[15]
        screen.offset = screen.scrollGeometry.bottomOffset
        presenter.jump(toMessage: MessageLink(roomId: message.roomId, eventId: message.eventId))
        try await screen.changes.until { !screen.glides.isEmpty }
        // rows above the message go while the chat glides: its row moves up, and the update puts it
        // in the middle; the glide's end, late, changes nothing.
        presenter.show(Array(all.dropFirst(5)))
        try await screen.changes.until { !screen.flashed.isEmpty }
        #expect(screen.glides.count == 1)
        #expect(screen.flashed == [message.id])
        #expect(!presenter.isJumping)
        #expect(screen.centres(message.id))
        presenter.didEndScrolling()
        #expect(screen.flashed == [message.id])
        #expect(screen.centres(message.id))
    }

    @Test func aChatOpensInPlaceWithTheRowsOfItsOpeningGoingInUnanimated() async throws {
        // 1 000 messages a chat: the device's timeline holds more than the opening fill, and the page
        // before it, asked for at once, goes in from what it holds, with nothing loading.
        let long = try DemoSessions.open(rooms: 3, messagesPerRoom: 1_000)
        let rows = try await long.account.value.chats()
        let row = try #require(rows.first { !$0.isMerged && !$0.isUnread })
        let presenter = ThreadPresenter(session: long, row: row, removeDelivered: { _ in })
        let screen = StackedScreen()
        presenter.screen = screen
        screen.presenter = presenter
        presenter.onLoading = { _ in screen.changes.send() }
        presenter.measure(with: GridMeasure())
        presenter.resize(to: 390)
        presenter.start()
        try await screen.changes.until { !(screen.shown.first ?? []).isEmpty }
        let opening = try #require(screen.shown.first).count
        presenter.didShowFirst()
        // the page before the opening fill is in, and nothing loads.
        try await screen.changes.until { (screen.shown.last ?? []).count > opening && !presenter.model.isLoading && presenter.model.canLoadOlder }
        #expect(screen.intents.allSatisfy { !$0.isAnimated })
        #expect(screen.glides.isEmpty)
        #expect(screen.scrollGeometry.isAtBottom)
    }

    @Test func aMessageTheUserSendsTakesTheChatToItsNewest() async throws {
        let (presenter, screen) = try await opened()
        try await screen.changes.until { (screen.shown.last ?? []).count > 20 && !presenter.model.isLoading }
        presenter.didShowFirst()
        screen.offset = 0
        presenter.model.send("on my way")
        try await screen.changes.until { screen.shown.last?.last?.body == "on my way" }
        // it slides there, as Messages has it.
        #expect(screen.glides.last == screen.scrollGeometry.range.upperBound)
        screen.arrive()
        #expect(screen.scrollGeometry.isAtBottom)
    }

    @Test func aMessageArrivingWhileTheReaderIsAboveKeepsTheirRowAndAtTheNewestFollowsIt() async throws {
        let (presenter, screen) = try await opened()
        try await screen.changes.until { (screen.shown.last ?? []).count > 20 && !presenter.model.isLoading }
        presenter.didShowFirst()
        // another chat sends a copy of one of its messages here: not one the user sent from this chat.
        let rows = try await session.account.value.chats()
        let other = ThreadModel(session: session, row: try #require(rows.first { !$0.isMerged && $0.id != presenter.model.chatId }))
        let otherChanges = other.changes()
        await other.start()
        try await otherChanges.until { !other.messages.isEmpty }
        let copied = try #require(other.messages.last)
        screen.offset = 300
        let reading = try #require(screen.readingRow)
        let top = try #require(screen.rowSpan(of: reading)).minY - screen.offset
        let count = presenter.model.messages.count
        other.forward(copied.id, to: presenter.model.chatId)
        try await screen.changes.until { (screen.shown.last ?? []).count > count }
        #expect(try #require(screen.rowSpan(of: reading)).minY - screen.offset == top)
        // at the newest, the next one is followed: the list slides to it.
        screen.offset = screen.scrollGeometry.bottomOffset
        other.forward(copied.id, to: presenter.model.chatId)
        try await screen.changes.until { (screen.shown.last ?? []).count > count + 1 }
        #expect(screen.glides.last == screen.scrollGeometry.range.upperBound)
        // one more while it slides: the list still counts as at the newest, and follows it too.
        let glides = screen.glides.count
        other.forward(copied.id, to: presenter.model.chatId)
        try await screen.changes.until { (screen.shown.last ?? []).count > count + 2 }
        #expect(screen.glides.count == glides + 1)
        #expect(screen.glides.last == screen.scrollGeometry.range.upperBound)
        screen.arrive()
        #expect(screen.scrollGeometry.isAtBottom)
    }

    @Test func theReaderScrollingDuringAGlideEndsItWithoutAFlash() async throws {
        let (presenter, screen) = try await opened()
        try await screen.changes.until { (screen.shown.last ?? []).count > 20 && !presenter.model.isLoading }
        presenter.didShowFirst()
        let message = presenter.model.messages[15]
        screen.offset = screen.scrollGeometry.bottomOffset
        presenter.jump(toMessage: MessageLink(roomId: message.roomId, eventId: message.eventId))
        try await screen.changes.until { presenter.isJumping }
        presenter.userStartedScrolling()
        #expect(!presenter.isJumping)
        screen.arrive()
        #expect(screen.flashed.isEmpty)
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

    @Test func aJumpsRowsReachingTheNewestGoLiveWithTheReadersRowWhereItWas() async throws {
        // 400 messages a chat: the device's live timeline holds the newest 200, the message is a jump away.
        let long = try DemoSessions.open(rooms: 3, messagesPerRoom: 400)
        let rows = try await long.account.value.chats()
        let row = try #require(rows.first { !$0.isMerged })
        let presenter = ThreadPresenter(session: long, row: row, focus: MessageLink(roomId: row.id, eventId: "\(row.id)/150"),
                                        removeDelivered: { _ in })
        let screen = StackedScreen()
        presenter.screen = screen
        screen.presenter = presenter
        presenter.measure(with: GridMeasure())
        presenter.resize(to: 390)
        presenter.start()
        let changes = presenter.model.changes()
        try await changes.until { !presenter.model.isLive && presenter.model.messages.contains { $0.eventId == "\(row.id)/150" } }
        presenter.didShowFirst()
        // the reader reads a message the live rows hold only once paged back to, and pages to the newest.
        try await screen.changes.until { screen.order.contains("\(row.id)/190") }
        screen.offset = try #require(screen.rowSpan(of: "\(row.id)/190")).minY
        let top = try #require(screen.rowSpan(of: "\(row.id)/190")).minY - screen.offset
        presenter.displayed(screen.scrollGeometry)
        while !presenter.model.isLive {
            presenter.model.loadNewer()
            try await changes.until { presenter.model.isLive || presenter.model.canLoadNewer }
        }
        try await screen.changes.until { screen.order.last == "\(row.id)/399" }
        // the same message is the same row in both: it stays where the reader saw it.
        #expect(screen.readingRow == "\(row.id)/190")
        #expect(try #require(screen.rowSpan(of: "\(row.id)/190")).minY - screen.offset == top)
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

