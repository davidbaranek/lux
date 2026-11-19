import Foundation
@testable import LuxCore
import Testing

/// The open chat as Handoff passes it to another device: what one device offers, the other opens.
struct ChatActivityTests {
    @Test func aChatOfferedOnOneDeviceIsTheChatTheOtherOpens() {
        let chat = ChatActivity(roomId: "!room:example.org")
        #expect(ChatActivity(chat.activity()) == chat)
    }

    @Test func aChatsOpenThreadGoesWithIt() {
        let thread = ChatActivity(roomId: "!room:example.org", threadRoot: "$root")
        #expect(ChatActivity(thread.activity()) == thread)
    }

    @Test func itIsOfferedForHandoffOnlyNeverToSearchOrSuggestions() {
        let activity = ChatActivity(roomId: "!room:example.org").activity()
        #expect(activity.isEligibleForHandoff)
        #expect(!activity.isEligibleForSearch)
        #expect(!activity.isEligibleForPublicIndexing)
        #expect(activity.title == nil)
    }

    @Test func itCarriesTheRoomAndTheThreadAndNothingElse() {
        let activity = ChatActivity(roomId: "!room:example.org", threadRoot: "$root").activity()
        #expect(Set(activity.userInfo?.keys.compactMap { $0 as? String } ?? []) == ["room", "thread"])
    }

    @Test func anotherKindOfActivityOpensNoChat() {
        let other = NSUserActivity(activityType: "com.example.other")
        other.addUserInfoEntries(from: ["room": "!room:example.org"])
        #expect(ChatActivity(other) == nil)
        #expect(ChatActivity(NSUserActivity(activityType: ChatActivity.type)) == nil)
    }
}
