import Foundation
import LuxBindings
import Testing
import UserNotifications
@testable import LuxCore

struct PushTests {
    @Test func aPushCarriesTheEventsIds() {
        let payload = PushPayload(userInfo: ["room_id": "!a:server", "event_id": "$e", "unread_count": 3,
                                             "aps": ["mutable-content": 1]])
        #expect(payload?.roomId == "!a:server" && payload?.eventId == "$e" )
        #expect(PushPayload(userInfo: ["room_id": "!a:server"]) == nil)
        // a reminder's notification names its room its own way.
        #expect(PushNotifications.room(of: ["roomId": "!b:server"]) == "!b:server")
    }

    @Test func aDevelopmentProfilePushesThroughTheSandbox() {
        let profile = Data("""
        garbage<plist><dict><key>Entitlements</key><dict>
        <key>aps-environment</key>
        <string>development</string></dict></dict></plist>garbage
        """.utf8)
        #expect(PushEnvironment.environment(ofProfile: profile) == .sandbox)
        let production = Data("<key>aps-environment</key>\n<string>production</string>".utf8)
        #expect(PushEnvironment.environment(ofProfile: production) == .production)
        #expect(PushEnvironment.environment(ofProfile: Data()) == .production)
    }

    @Test func aDirectMessageIsTitledByItsSenderAndAGroupsByItsChat() {
        let direct = PushedMessage(notification(room: "!a:server", chat: "Anna", isGroup: false, kind: .text(text: "see you")))
        #expect(direct.title == "Anna" && direct.subtitle.isEmpty && direct.body == "see you")
        let group = PushedMessage(notification(room: "!b:server", chat: "Trip", isGroup: true, kind: .image))
        #expect(group.title == "Trip" && group.subtitle == "Anna" && group.body == "Photo")
        let reaction = PushedMessage(notification(room: "!a:server", chat: "Anna", isGroup: false, kind: .reaction(key: "❤️")))
        #expect(reaction.body == "Reacted ❤️")
    }

    @Test func aMergedRoomsMessageGroupsWithTheMergedChatAndKeepsItsPictures() {
        var core = notification(room: "!b:server", chat: "Jana", isGroup: false, kind: .text(text: "hi"))
        core.chatId = "merge:jana"
        core.senderImage = Data([1, 2, 3])
        let message = PushedMessage(core)
        #expect(message.chatId == "merge:jana" && message.roomId == "!b:server" && message.eventId == "$e")
        #expect(message.senderImage == Data([1, 2, 3]))
    }

    @Test func aThreadsReplyCarriesItsThreadToItsNotificationsActions() throws {
        var core = notification(room: "!r:server", chat: "Crew", isGroup: true, kind: .text(text: "see you"))
        core.threadRoot = "$root"
        let message = PushedMessage(core)
        #expect(message.threadRoot == "$root")
        let payload = try #require(PushPayload(userInfo: message.userInfo))
        #expect(payload.roomId == "!r:server" && payload.eventId == "$e" && payload.threadRoot == "$root")
        // a message in the chat's own timeline names no thread.
        let plain = PushedMessage(notification(room: "!r:server", chat: "Crew", isGroup: true, kind: .text(text: "hi")))
        #expect(PushPayload(userInfo: plain.userInfo)?.threadRoot == nil)
    }

    /// A push the rules say does not notify (an encrypted chat's reaction, which the server cannot
    /// read): dropped with Apple's filtering entitlement; without it, the neutral text in the
    /// notification list only, never a sound or a lit screen.
    @Test func aPushNotToBeShownIsDroppedOrQuiet() {
        let neutral = UNMutableNotificationContent()
        neutral.body = "New message"
        neutral.sound = .default
        neutral.threadIdentifier = "!a:server"
        let dropped = PushNotifications.notShown(neutral, dropping: true)
        #expect(dropped.body.isEmpty && dropped.title.isEmpty && dropped.sound == nil)
        let quiet = PushNotifications.notShown(neutral, dropping: false)
        #expect(quiet.body == "New message" && quiet.threadIdentifier == "!a:server")
        #expect(quiet.sound == nil && quiet.interruptionLevel == .passive)
        // the neutral text a failure shows is left as it was.
        #expect(neutral.sound == .default && neutral.interruptionLevel == .active)
    }

    private func notification(room: String, chat: String, isGroup: Bool, kind: CorePreviewKind) -> CoreNotification {
        CoreNotification(roomId: room, eventId: "$e", chatId: room, chatName: chat, senderId: "@anna:example.org", senderName: "Anna", isGroup: isGroup, kind: kind,
                         isNoisy: true, isLate: false, senderImage: nil, threadRoot: nil)
    }
}
