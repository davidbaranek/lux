import Foundation
import Testing
import LuxBindings
@testable import LuxCore

@MainActor
@Suite(.closesDemoSessions, .timeLimit(.minutes(1)))
struct DemoThreadTests {
    @Test func reactionsToggle() async throws {
        let session = try DemoSessions.open(rooms: 3, messagesPerRoom: 10)
        let row = try #require(await session.account.value.chats().first)
        let model = ThreadModel(session: session, row: row)
        let changes = model.changes()
        await model.start()
        try await changes.until { !model.messages.isEmpty }
        let first = model.messages[0].id
        model.toggleReaction("👍", on: first)
        try await changes.until { model.messages[0].reactions.contains { $0.key == "👍" && $0.isMine } }
        model.toggleReaction("👍", on: first)
        try await changes.until { !model.messages[0].reactions.contains { $0.key == "👍" } }
    }

    @Test func aSentMessageShowsAndAnAnswerGoesToItsMessage() async throws {
        let session = try DemoSessions.open(rooms: 3, messagesPerRoom: 10)
        let row = try #require(await session.account.value.chats().first)
        let model = ThreadModel(session: session, row: row)
        let changes = model.changes()
        await model.start()
        try await changes.until { !model.messages.isEmpty }
        model.reply(to: model.messages[0])
        try await changes.until { model.mode != .message }
        model.send("  hello  ")
        try await changes.until { model.messages.last?.body == "hello" }
        #expect(model.messages.last?.quote != nil)
        #expect(model.mode == .message)
    }
}

/// Matrix threads in the demo: a root's summary in the chat, the thread's own timeline, replying
/// there, the chat's threads, and joining a bridged thread by its reaction (mautrix-discord's).
@MainActor
@Suite(.closesDemoSessions, .timeLimit(.minutes(1)))
struct DemoMatrixThreadTests {
    private let session: Session

    init() throws {
        session = try DemoSessions.open(rooms: 6, messagesPerRoom: 30)
    }

    private func opened(_ thread: MatrixThread? = nil, in chat: ChatRow? = nil) async throws -> (ThreadModel, Changes) {
        let first = try await session.account.value.chats().first
        let row = try #require(chat ?? first)
        let model = ThreadModel(session: session, row: row, thread: thread)
        let changes = model.changes()
        await model.start()
        try await changes.until { !model.messages.isEmpty }
        return (model, changes)
    }

    @Test func aThreadOpensAtItsRootAndWhatIsSentThereCountsOnTheRoot() async throws {
        let (chat, chatChanges) = try await opened()
        let root = try #require(chat.messages.last { $0.thread != nil })
        let before = try #require(root.thread?.replies)
        let (thread, changes) = try await opened(MatrixThread(roomId: root.roomId, rootEventId: root.eventId))
        #expect(thread.messages.first?.eventId == root.eventId)
        #expect(thread.messages.count == before + 1)
        thread.send("in the thread")
        try await changes.until { thread.messages.last?.body == "in the thread" }
        try await chatChanges.until { chat.messages.first { $0.eventId == root.eventId }?.thread?.replies == before + 1 }
        #expect(!chat.messages.contains { $0.body == "in the thread" })
    }

    @Test func theChatsThreadsListTheLatestActiveFirst() async throws {
        let row = try #require(await session.account.value.chats().first)
        let threads = session.details(of: row).threads()
        let changes = Changes()
        let observation = threads.changes.observe { changes.send() }
        await threads.loadMore()
        try await changes.until { !threads.threads.isEmpty }
        withExtendedLifetime(observation) {}
        #expect(threads.threads == threads.threads.sorted { $0.activity > $1.activity })
    }

    @Test func reactingJoinThreadToTheBridgesNoticeBringsTheThreadsReplies() async throws {
        for row in try await session.account.value.chats() where !row.isMerged {
            let (chat, _) = try await opened(in: row)
            for root in chat.messages where root.thread != nil {
                let (thread, changes) = try await opened(MatrixThread(roomId: root.roomId, rootEventId: root.eventId), in: row)
                guard let notice = thread.messages.first(where: { $0.body.hasPrefix("Thread created.") }) else { continue }
                #expect(notice.reactions.contains { $0.key == "join thread" && !$0.isMine })
                let before = thread.messages.count
                thread.toggleReaction("join thread", on: notice.id)
                try await changes.until { thread.messages.count == before + 2 }
                return
            }
        }
        Issue.record("no bridged thread among the demo's")
    }
}

/// The account's chats as the core reads them, beside the chat list.
@MainActor
@Suite(.closesDemoSessions, .timeLimit(.minutes(1)))
struct DemoChatsTests {
    private let session: Session

    init() throws {
        session = try DemoSessions.open(rooms: 30, messagesPerRoom: 5)
    }

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
