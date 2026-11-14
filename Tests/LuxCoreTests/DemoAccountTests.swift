import Foundation
import Testing
import LuxBindings
@testable import LuxCore

@MainActor
struct DemoThreadTests {
    @Test func reactionsToggle() async throws {
        let session = Session.demo(rooms: 3, messagesPerRoom: 10)
        let row = try #require(await session.account.value.chats().first)
        let model = ThreadModel(session: session, row: row)
        let changes = model.changes()
        await model.start()
        await changes.until { !model.messages.isEmpty }
        let first = model.messages[0].id
        model.toggleReaction("👍", on: first)
        await changes.until { model.messages[0].reactions.contains { $0.key == "👍" && $0.isMine } }
        model.toggleReaction("👍", on: first)
        await changes.until { !model.messages[0].reactions.contains { $0.key == "👍" } }
    }

    @Test func aSentMessageShowsAndAnAnswerGoesToItsMessage() async throws {
        let session = Session.demo(rooms: 3, messagesPerRoom: 10)
        let row = try #require(await session.account.value.chats().first)
        let model = ThreadModel(session: session, row: row)
        let changes = model.changes()
        await model.start()
        await changes.until { !model.messages.isEmpty }
        model.reply(to: model.messages[0])
        await changes.until { model.mode != .message }
        model.send("  hello  ")
        await changes.until { model.messages.last?.body == "hello" }
        #expect(model.messages.last?.quote != nil)
        #expect(model.mode == .message)
    }
}

/// The account's chats as the core reads them, beside the chat list.
@MainActor
struct DemoChatsTests {
    private let session = Session.demo(rooms: 30, messagesPerRoom: 5)

    @Test func aChatIsFoundByTheWordsOfItsNameWithoutCaseOrAccents() async throws {
        let account = try await session.account.value
        let chat = try #require(await account.chats().first { $0.name.contains(" ") })
        let words = chat.name.split(separator: " ").reversed().joined(separator: " ").uppercased()
        let found = await account.findChats(words, limit: 20)
        #expect(found.contains { $0.id == chat.id })
        #expect(await account.findChats("zzz-no-such-chat", limit: 20).isEmpty)
    }

    @Test func aRoomOfAMergedChatOpensTheMergedChat() async throws {
        let shown = await session.chat(ofRoom: "!room18:demo")
        #expect(shown?.isMerged == true)
        #expect(shown?.rooms.map(\.id) == ["!room4:demo", "!room18:demo"])
    }
}

/// The core's errors, as the user reads them.
struct AccountFailureTests {
    @Test func aServerOrNetworkFailureIsToldByItsKind() {
        #expect(AccountFailure(CoreAccountError.Server(status: 429, errcode: nil, message: "")) == .rateLimited)
        #expect(AccountFailure(CoreAccountError.Server(status: 403, errcode: "M_FORBIDDEN", message: "")) == .forbidden)
        #expect(AccountFailure(CoreAccountError.Server(status: 502, errcode: nil, message: "")) == .serverUnavailable)
        #expect(AccountFailure(CoreAccountError.Network(kind: .offline, message: "")) == .offline)
        #expect(AccountFailure.offline.isForTheUser == false)
    }
}
