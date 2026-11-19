import Foundation
import Testing
@testable import LuxCore

@MainActor
@Suite(.closesDemoSessions, .timeLimit(.minutes(1)))
struct PinnedMessagesTests {
    private let session: Session

    init() throws {
        session = try DemoSessions.open(rooms: 30, messagesPerRoom: 40)
    }

    /// The demo pins a message in every third room; none was seen yet.
    private func pinnedChat() async throws -> ThreadModel {
        let rows = try await session.account.value.chats()
        let row = try #require(rows.first { $0.id == "!room3:demo" })
        return ThreadModel(session: session, row: row)
    }

    @Test func aNewPinIsToldUntilSeenAndStaysPinned() async throws {
        let model = try await pinnedChat()
        let changes = model.changes()
        await model.start()
        try await changes.until { model.newPin != nil }
        let pin = try #require(model.newPin)
        #expect(model.pinned == [pin])
        #expect(model.mayUnpin(pin))

        model.pinsSeen()
        try await changes.until { model.newPin == nil }
        #expect(model.pinned == [pin], "seen, still pinned")
    }

    @Test func aPinIsUnpinnedFromTheListByItsEvent() async throws {
        let model = try await pinnedChat()
        let changes = model.changes()
        await model.start()
        try await changes.until { !model.pinned.isEmpty }
        let pin = try #require(model.pinned.first)
        model.unpin(pin)
        try await changes.until { model.pinned.isEmpty }
        #expect(model.newPin == nil)
    }
}
