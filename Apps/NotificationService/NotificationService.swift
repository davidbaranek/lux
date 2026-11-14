import Intents
import LuxCore
import UserNotifications

/// Shows a pushed message with its sender, chat, text and pictures: the server pushed only the
/// event's id, and the account's store, shared with the app, opens here to fetch and decrypt it.
/// Whatever fails, the notification says only "New message" (the push's own text), never the
/// payload.
///
/// An event that is not to be shown (the push rules say it does not notify, or it was deleted)
/// can be dropped only with Apple's filtering entitlement; without it the system shows whatever
/// the extension hands back, so it shows the neutral text, as for a failure.
final class NotificationService: UNNotificationServiceExtension {
    private var delivery: Delivery?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let delivery = Delivery(neutral: Self.neutral(request.content), handler: contentHandler)
        self.delivery = delivery
        guard let payload = PushPayload(userInfo: request.content.userInfo) else {
            delivery.deliverNeutral()
            return
        }
        Task { await delivery.fill(from: payload) }
    }

    override func serviceExtensionTimeWillExpire() {
        // out of time: the neutral text, at once.
        delivery?.deliverNeutral()
    }

    /// The push as it came, its text neutral whatever the payload said, grouped by its chat, with
    /// the server's badge.
    private static func neutral(_ pushed: UNNotificationContent) -> UNNotificationContent {
        let content = UNMutableNotificationContent()
        content.body = String(localized: "New message")
        content.sound = .default
        content.userInfo = pushed.userInfo
        content.categoryIdentifier = PushNotifications.messageCategory
        if let payload = PushPayload(userInfo: pushed.userInfo) {
            content.threadIdentifier = payload.roomId
            if let unread = payload.unreadCount { content.badge = NSNumber(value: unread) }
        }
        return content.copy() as? UNNotificationContent ?? content
    }
}

/// One notification's content on its way to the system: handed over once, filled in or neutral,
/// whichever comes first (the reading, or the extension's deadline). `@unchecked`: the handler (the
/// system's, not `Sendable`) is only read and cleared under `lock`, and `neutral` (a
/// `UNNotificationContent`, not `Sendable`) is never changed: what is filled in is a copy. A
/// `Mutex` would not remove it: the system's handler and content cannot be sent into one.
private final class Delivery: @unchecked Sendable {
    /// One account per process: iOS may keep the extension running for the next notification.
    private static let events = EventsHolder()

    private let neutral: UNNotificationContent
    private let lock = NSLock()
    /// The system's handler, taken by the first delivery, under `lock`.
    private var handler: ((UNNotificationContent) -> Void)?

    init(neutral: UNNotificationContent, handler: @escaping (UNNotificationContent) -> Void) {
        self.neutral = neutral
        self.handler = handler
    }

    func deliverNeutral() { deliver(neutral) }

    /// Whether this build has the filtering entitlement (`com.apple.developer.usernotifications.
    /// filtering`), which lets an extension drop a notification by handing back empty content.
    /// The entitlement cannot be read at run time on iOS: `project.yml` sets this key beside it.
    private static let filters = Bundle.main.object(forInfoDictionaryKey: "LuxFiltersNotifications") as? Bool ?? false

    /// Reads the pushed event and shows it; anything that fails shows the neutral text.
    func fill(from payload: PushPayload) async {
        do {
            guard let events = try await Self.events.open() else {
                deliverNeutral()
                return
            }
            guard let message = try await events.read(payload) else {
                // not to be shown: dropped where the system allows it.
                if Self.filters { deliver(UNNotificationContent()) } else { deliverNeutral() }
                return
            }
            guard let content = neutral.mutableCopy() as? UNMutableNotificationContent else {
                deliverNeutral()
                return
            }
            content.title = message.title
            content.subtitle = message.subtitle
            content.body = message.body
            content.sound = message.isNoisy ? .default : nil
            // a merged chat's rooms in one group, as the chat list shows them.
            content.threadIdentifier = message.chatId
            deliver(Self.quietIfLate(await Self.communication(content, message) ?? content, message))
        } catch {
            Log.app.error("notification: \(String(describing: error), privacy: .public)")
            deliverNeutral()
        }
    }

    /// History a bridge brings in (a message that came late): in the notification centre, without
    /// a sound and without lighting the screen. Set last: the intent's update makes new content.
    private static func quietIfLate(_ content: UNNotificationContent, _ message: PushedMessage) -> UNNotificationContent {
        guard message.isLate, let quiet = content.mutableCopy() as? UNMutableNotificationContent else { return content }
        quiet.interruptionLevel = .passive
        quiet.sound = nil
        return quiet.copy() as? UNNotificationContent ?? quiet
    }

    private func deliver(_ content: UNNotificationContent) {
        let handler = lock.withLock { self.handler.take() }
        handler?(content)
    }

    /// The notification as a message from a person (their picture and name over it, a group's
    /// picture and name for a group, Focus letting the people it allows through), when the system
    /// takes it. The interaction is donated first, as the system asks: content updated from an
    /// intent it has not been told of shows as the app's.
    private static func communication(_ content: UNNotificationContent, _ message: PushedMessage) async -> UNNotificationContent? {
        let sender = INPerson(personHandle: INPersonHandle(value: message.senderName, type: .unknown), nameComponents: nil,
                              displayName: message.senderName, image: message.senderImage.map { INImage(imageData: $0) },
                              contactIdentifier: nil, customIdentifier: nil)
        let group = message.isGroup ? INSpeakableString(spokenPhrase: message.chatName) : nil
        // a group needs a second person among the recipients to show as a group.
        let intent = INSendMessageIntent(recipients: message.isGroup ? [sender, Self.me] : nil, outgoingMessageType: .outgoingMessageText,
                                         content: message.body, speakableGroupName: group,
                                         conversationIdentifier: message.chatId, serviceName: nil, sender: sender, attachments: nil)
        if message.isGroup, let picture = message.chatImage {
            intent.setImage(INImage(imageData: picture), forParameterNamed: \.speakableGroupName)
        }
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        do {
            try await interaction.donate()
            return try content.updating(from: intent)
        } catch {
            Log.app.error("notification: not from a person: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// The account's user, as a group's other recipient.
    private static var me: INPerson {
        INPerson(personHandle: INPersonHandle(value: "me", type: .unknown), nameComponents: nil, displayName: nil, image: nil,
                 contactIdentifier: nil, customIdentifier: nil, isMe: true)
    }
}

/// The account, opened on the first notification and kept for the next ones. Two pushes close
/// together share one opening: the actor is re-entered while the first one awaits, and a second
/// account over the same store would double the extension's memory.
private actor EventsHolder {
    private var opening: Task<PushedEvents?, any Error>?

    func open() async throws -> PushedEvents? {
        let opening = self.opening ?? Task { try await PushedEvents.open() }
        self.opening = opening
        do {
            if let events = try await opening.value { return events }
            forget(opening)
            return nil
        } catch {
            forget(opening)
            throw error
        }
    }

    /// No account, or it failed to open: the next push tries again (unless one already does).
    private func forget(_ failed: Task<PushedEvents?, any Error>) {
        if opening == failed { opening = nil }
    }
}
