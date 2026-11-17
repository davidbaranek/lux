import Foundation
import Testing
@testable import LuxCore

struct BadgeStateTests {
    /// Two counted chats (one merged, by its id and its rooms), two rooms the inbox does not count.
    private let kept = BadgeState(count: 2, counted: ["!a:s", "merge:jana", "!w:s", "!t:s"], uncounted: ["!archived:s", "!muted:s"])

    @Test func aMessageInAChatAlreadyCountedKeepsTheCount() {
        var state = kept
        #expect(state.count(messageIn: "!a:s", of: "!a:s") == 2)
        // a merged chat's other room, by the chat or by the room alone (its message not read).
        #expect(state.count(messageIn: "!t:s", of: "merge:jana") == 2)
        #expect(state.count(messageIn: "!w:s", of: "!w:s") == 2)
        #expect(state == kept)
    }

    @Test func aMessageInARoomTheInboxDoesNotCountKeepsTheCount() {
        var state = kept
        #expect(state.count(messageIn: "!archived:s", of: "!archived:s") == 2)
        #expect(state.count(messageIn: "!muted:s", of: "!muted:s") == 2)
        #expect(state == kept)
    }

    @Test func aMessageInAReadChatOfTheInboxCountsOnceThenIsCounted() {
        var state = kept
        #expect(state.count(messageIn: "!b:s", of: "!b:s") == 3)
        #expect(state.count(messageIn: "!b:s", of: "!b:s") == 3)
    }

    @Test func aMessageInARoomTheAppHasNotSeenCountsAsANewChatOfTheInbox() {
        var state = kept
        #expect(state.count(messageIn: "!new:s", of: "!new:s") == 3)
        // a read merged chat's room: counted by the chat, so its other room keeps the count.
        #expect(state.count(messageIn: "!x:s", of: "merge:petr") == 4)
        #expect(state.count(messageIn: "!y:s", of: "merge:petr") == 4)
    }

    @Test func theBadgeIsKeptForTheExtensionAndCountedOnThere() throws {
        let suite = "lux-badge-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // before the app kept one: nothing to count on, the badge stays.
        #expect(BadgeState.count(messageIn: "!b:s", of: "!b:s", in: defaults) == nil)
        kept.keep(in: defaults)
        #expect(BadgeState.kept(in: defaults) == kept)
        #expect(BadgeState.count(messageIn: "!b:s", of: "!b:s", in: defaults) == 3)
        #expect(BadgeState.count(messageIn: "!b:s", of: "!b:s", in: defaults) == 3)
        #expect(BadgeState.kept(in: defaults)?.count == 3)
        // the app counts again: what it keeps replaces what the extension counted.
        BadgeState.empty.keep(in: defaults)
        #expect(BadgeState.kept(in: defaults) == .empty)
    }
}
