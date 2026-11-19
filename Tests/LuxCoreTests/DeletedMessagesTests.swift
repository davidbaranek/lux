import Foundation
import Testing
@testable import LuxCore

/// Deleted messages one after another, as the chat's model shows them over the demo: one row
/// that says how many, which a tap unfolds.
@MainActor
@Suite(.closesDemoSessions, .timeLimit(.minutes(1)))
struct DeletedMessagesTests {
    private let session: Session

    init() throws {
        session = try DemoSessions.open(rooms: 10, messagesPerRoom: 40)
    }

    /// A chat of one room, open, its messages in.
    private func opened() async throws -> (ThreadModel, Changes) {
        let rows = try await session.account.value.chats()
        let row = try #require(rows.first { !$0.isMerged })
        let model = ThreadModel(session: session, row: row)
        let changes = model.changes()
        await model.start()
        try await changes.until { model.messages.count > 3 }
        return (model, changes)
    }

    /// Three of the newest messages, one after another, that fold together once deleted (no
    /// album, no Matrix thread, no day or pause between them).
    private func threeToDelete(in messages: [MessageItem]) throws -> [String] {
        let start = messages.indices.dropLast(2).last { index in
            let three = messages[index...(index + 2)]
            return three.allSatisfy { $0.album.isEmpty && $0.thread == nil }
                && three.dropFirst().allSatisfy { !$0.startsDay && !$0.startsTimeGap }
        }
        let index = try #require(start)
        return messages[index...(index + 2)].map(\.id)
    }

    @Test func deletedMessagesOneAfterAnotherShowAsOneRowThatATapUnfolds() async throws {
        let (model, changes) = try await opened()
        let three = try threeToDelete(in: model.messages)
        for id in three { model.delete(id) }
        try await changes.until { model.messages.first { $0.id == three[0] }?.deletedRun == 3 }
        let folded = try #require(model.messages.first { $0.id == three[0] })
        #expect(folded.body == "3 deleted messages")
        #expect(folded.isDeleted)
        #expect(MessageAction.available(for: folded, inThread: false).isEmpty)
        #expect(!model.messages.contains { $0.id == three[1] || $0.id == three[2] })
        model.tap(folded)
        try await changes.until { three.allSatisfy { id in model.messages.contains { $0.id == id && $0.deletedRun == 0 } } }
        #expect(model.messages.filter { three.contains($0.id) }.allSatisfy { $0.isDeleted && !$0.showsDetail })
    }

    @Test func aSingleDeletedMessageKeepsItsOwnRow() async throws {
        let (model, changes) = try await opened()
        let id = try #require(model.messages.last { $0.album.isEmpty }?.id)
        model.delete(id)
        try await changes.until { model.messages.first { $0.id == id }?.isDeleted == true }
        #expect(model.messages.first { $0.id == id }?.deletedRun == 0)
    }
}
