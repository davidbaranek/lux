import Foundation
import UserNotifications

/// What the app's and the extension's notifications share: the message category and its actions,
/// and clearing a chat's notifications once it was read.
public enum PushNotifications {
    /// A message's notification: Reply and Mark as Read.
    public static let messageCategory = "message"
    public static let replyAction = "reply"
    public static let readAction = "read"

    public static var categories: Set<UNNotificationCategory> {
        let reply = UNTextInputNotificationAction(identifier: replyAction, title: String(localized: "Reply"), options: [],
                                                  textInputButtonTitle: String(localized: "Send"),
                                                  textInputPlaceholder: String(localized: "Message"))
        let read = UNNotificationAction(identifier: readAction, title: String(localized: "Mark as Read"), options: [])
        return [UNNotificationCategory(identifier: messageCategory, actions: [reply, read], intentIdentifiers: [],
                                       options: [])]
    }

    /// `content` in the notification list only: without a sound, and without lighting the screen
    /// (`.passive`).
    public static func quiet(_ content: UNNotificationContent) -> UNNotificationContent {
        guard let quiet = content.mutableCopy() as? UNMutableNotificationContent else { return content }
        quiet.interruptionLevel = .passive
        quiet.sound = nil
        return quiet.copy() as? UNNotificationContent ?? quiet
    }

    /// What the extension hands back for a pushed event that is not to be shown (the push rules
    /// say it does not notify, as for a reaction or a bot's notice in an encrypted chat, which the
    /// server cannot read and so pushes; or it was deleted): nothing where the extension may drop
    /// it (Apple's filtering entitlement, `dropping`), else the system shows whatever it is handed,
    /// so the `neutral` text, [quiet](quiet(_:)), as the push rules ask.
    public static func notShown(_ neutral: UNNotificationContent, dropping: Bool) -> UNNotificationContent {
        dropping ? UNNotificationContent() : quiet(neutral)
    }

    /// The room a notification is for: a pushed message's, or a reminder's.
    public static func room(of userInfo: [AnyHashable: Any]) -> String? {
        PushPayload(userInfo: userInfo)?.roomId ?? userInfo["roomId"] as? String
    }

    /// Removes the delivered notifications of `rooms` (their chat was read or opened).
    public static func removeDelivered(rooms: Set<String>) async {
        guard !rooms.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications()
        let gone = delivered.filter { note in
            // a pushed message's thread is its room.
            rooms.contains(note.request.content.threadIdentifier) || (PushPayload(userInfo: note.request.content.userInfo).map { rooms.contains($0.roomId) } ?? false)
        }
        center.removeDeliveredNotifications(withIdentifiers: gone.map(\.request.identifier))
    }
}

/// What the user did with a message's notification (or a reminder's), read once from the
/// system's response so both apps answer it the same way. `thread` is the Matrix thread the
/// message came in, by its root: the reply goes there, the read is the thread's, and it opens.
public enum NotificationAction: Sendable, Equatable {
    /// Reply, with the text typed; `event` is the message answered, read once the reply went.
    case reply(room: String, thread: String?, event: String?, text: String)
    case markRead(room: String, thread: String?, event: String)
    /// The notification itself was tapped or clicked: its chat opens (at its thread).
    case open(room: String, thread: String?)

    /// Nil for a notification of no room, an empty reply, or an action the app does not offer.
    public init?(_ response: UNNotificationResponse) {
        let userInfo = response.notification.request.content.userInfo
        guard let room = PushNotifications.room(of: userInfo) else { return nil }
        let payload = PushPayload(userInfo: userInfo)
        let (event, thread) = (payload?.eventId, payload?.threadRoot)
        switch response.actionIdentifier {
        case PushNotifications.replyAction:
            guard let text = (response as? UNTextInputNotificationResponse)?.userText,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            self = .reply(room: room, thread: thread, event: event, text: text)
        case PushNotifications.readAction:
            guard let event else { return nil }
            self = .markRead(room: room, thread: thread, event: event)
        case UNNotificationDefaultActionIdentifier:
            self = .open(room: room, thread: thread)
        default:
            return nil
        }
    }
}

extension Session {
    /// Answers a notification's Reply or Mark as Read on the account, opening it first if the
    /// system launched the app for it. The chat's notifications go once it is answered or read; a
    /// reply that did not go says so in a notification of its own. Opening a chat is the app's.
    public func answer(_ action: NotificationAction) async {
        _ = await restore()
        switch action {
        case let .reply(room, thread, event, text):
            do {
                try await reply(roomId: room, threadRoot: thread, text: text)
            } catch {
                Log.app.error("notification reply: \(String(describing: error), privacy: .public)")
                await PushNotifications.replyFailed()
                return
            }
            // answered: read up to the message.
            if let event { _ = await markRead(room: room, thread: thread, upTo: event) }
            await PushNotifications.removeDelivered(rooms: [room])
        case let .markRead(room, thread, event):
            if await markRead(room: room, thread: thread, upTo: event) { await PushNotifications.removeDelivered(rooms: [room]) }
        case .open:
            break
        }
    }

    /// Marks read from a notification; false (logged) when it failed.
    private func markRead(room: String, thread: String?, upTo event: String) async -> Bool {
        do {
            try await markRead(roomId: room, threadRoot: thread, upTo: event)
            return true
        } catch {
            Log.app.error("notification read: \(String(describing: error), privacy: .public)")
            return false
        }
    }
}

extension PushNotifications {
    /// A reply that did not go: the user hears of it.
    static func replyFailed() async {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Not sent")
        content.body = String(localized: "Your reply could not be sent. Open the chat to try again.")
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        await bestEffort("notification: reply not sent") { try await UNUserNotificationCenter.current().add(request) }
    }
}
