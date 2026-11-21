import Foundation
import Testing
@testable import LuxCore

/// Mentions through the thread's model over the demo: the `@` being typed, the members it offers
/// in a group, a pill sent and a pill that came, a message that mentions the account. What the
/// core decides (the spec's content, the ranking, a pill's name) is tested in `lux-core` and
/// `lux-matrix` (`mention.rs`, `tests/mentions.rs`).
@MainActor
@Suite(.closesDemoSessions, .timeLimit(.minutes(1)))
struct MentionTests {
    private let session: Session

    init() throws {
        session = try DemoSessions.open(rooms: 8, messagesPerRoom: 30)
    }

    private func group() async throws -> (ThreadModel, Changes) {
        let row = try #require(await session.account.value.chats().first { $0.isGroup })
        let model = ThreadModel(session: session, row: row)
        let changes = model.changes()
        await model.start()
        try await changes.until { !model.messages.isEmpty }
        return (model, changes)
    }

    @Test func theWordAfterAnAtIsTheMentionBeingTyped() {
        #expect(ComposedText.mentionQuery(in: "hi @an", cursor: 6) == MentionQuery(range: NSRange(location: 3, length: 3), text: "an"))
        #expect(ComposedText.mentionQuery(in: "me@example.org", cursor: 14) == nil)
        #expect(ComposedText.mentionQuery(in: "@anna ", cursor: 6) == nil)
    }

    @Test func aGroupOffersItsMembersBestMatchFirstButNeverTheAccount() async throws {
        let (model, _) = try await group()
        let everyone = await model.mentionSuggestions(for: MentionQuery(range: NSRange(location: 0, length: 1), text: ""))
        #expect(!everyone.isEmpty)
        #expect(!everyone.contains { if case .member(let member) = $0 { member.isOwn } else { false } })
        guard case .member(let first) = everyone.first else {
            Issue.record("no member first")
            return
        }
        let word = String(first.name.prefix(3))
        let found = await model.mentionSuggestions(for: MentionQuery(range: NSRange(location: 0, length: 4), text: word))
        #expect(found.first.map { if case .member(let member) = $0 { member.name.hasPrefix(word) } else { false } } == true)
    }

    @Test func thePillOfTheAccountIsKnownAsItsOwn() async throws {
        let (model, _) = try await group()
        #expect(await model.isAccount("@me:demo"))
        #expect(await !model.isAccount("@friend0:demo"))
    }

    @Test func aSentPillShowsAsAPillAndTheNewestFromOthersMentionsTheAccount() async throws {
        let (model, changes) = try await group()
        // the demo's newest message from others mentions the account, with its pill.
        let mentioning = try #require(model.messages.last { !$0.isOwn && $0.mentionsMe })
        #expect(mentioning.styles.contains { $0.kind == .mention(.user("@me:demo")) })
        #expect(model.messages.contains { message in
            !message.mentionsMe && message.styles.contains { $0.kind == .mention(.user("@friend1:demo")) }
        })

        model.send(ComposedText("ask Anna", mentions: [Mention(.user("@friend0:demo"), NSRange(location: 4, length: 4))]))
        try await changes.until { model.messages.last?.body == "ask Anna" }
        let sent = try #require(model.messages.last)
        #expect(sent.styles == [TextStyle(.mention(.user("@friend0:demo")), NSRange(location: 4, length: 4))])
    }

    @Test func anEditStartsFromTheMessageWithItsPills() async throws {
        let (model, changes) = try await group()
        let pill = Mention(.user("@friend0:demo"), NSRange(location: 4, length: 4))
        model.send(ComposedText("ask Anna", mentions: [pill]))
        try await changes.until { model.messages.last?.body == "ask Anna" }
        let sent = try #require(model.messages.last)
        model.edit(sent)
        try await changes.until { model.mode != .message }
        #expect(model.mode == .edit(messageId: sent.id, original: ComposedText("ask Anna", mentions: [pill])))
    }
}
