import Foundation
import Testing
@testable import LuxCore

@MainActor
@Suite(.closesDemoSessions)
struct MergedChatTests {
    private let session = DemoSessions.open(rooms: 30, messagesPerRoom: 40)

    private func merged() async throws -> ChatRow {
        let rows = try await session.account.value.chats()
        let row = rows.first { $0.isMerged }
        return try #require(row)
    }

    @Test func theListShowsOneRowForTheMergedRooms() async throws {
        let row = try await merged()
        let rows = try await session.account.value.chats()
        #expect(row.rooms.map(\.id) == ["!room4:demo", "!room18:demo"])
        #expect(!rows.contains { $0.id == "!room18:demo" || $0.id == "!room4:demo" })
    }

    @Test func allRoomsShowAsOneConversationInTimeOrderEachWithItsNetwork() async throws {
        let row = try await merged()
        let model = ThreadModel(session: session, row: row)
        let changes = model.changes()
        await model.start()
        await changes.until { Set(model.messages.map(\.roomId)).count == 2 }
        #expect(Set(model.messages.map(\.roomId)) == ["!room4:demo", "!room18:demo"])
        #expect(model.messages.map(\.date) == model.messages.map(\.date).sorted())
        #expect(Set(model.messages.compactMap(\.network)) == ["telegram", "whatsapp"])
        // the conversation's last message decides where a new one goes.
        #expect(model.sendRoom == model.messages.last?.roomId)
    }

    @Test func oneRoomAloneShowsOnlyItsMessagesAndTakesNewOnes() async throws {
        let row = try await merged()
        let model = ThreadModel(session: session, row: row)
        let changes = model.changes()
        await model.start()
        model.show(room: "!room18:demo")
        await changes.until { model.shownRoom == "!room18:demo" }
        #expect(Set(model.messages.map(\.roomId)) == ["!room18:demo"])
        #expect(model.sendRoom == "!room18:demo")
    }

    @Test func aTappedMessageShowsItsNetworkAndTime() async throws {
        let row = try await merged()
        let model = ThreadModel(session: session, row: row)
        let changes = model.changes()
        await model.start()
        await changes.until { !model.messages.isEmpty }
        let last = model.messages.last?.id
        let id = try #require(last)
        model.toggleDetail(of: id)
        await changes.until { model.messages.last?.showsDetail == true }
        #expect(model.messages.last?.detailText?.hasPrefix("WhatsApp · ") == true || model.messages.last?.detailText?.hasPrefix("Telegram · ") == true)
        model.toggleDetail(of: id)
        await changes.until { model.messages.last?.showsDetail == false }
        #expect(model.messages.last?.detailText == nil)
    }
}
