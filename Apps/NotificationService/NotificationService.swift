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
/// the extension hands back, so it shows the neutral text, quietly (`PushNotifications.notShown`).
final class NotificationService: UNNotificationServiceExtension {
    private var delivery: Delivery?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let payload = PushPayload(userInfo: request.content.userInfo)
        let delivery = Delivery(neutral: Self.neutral(request.content), room: payload?.roomId, handler: contentHandler)
        self.delivery = delivery
        guard let payload else {
            delivery.deliverNeutral()
            return
        }
        Task { await delivery.fill(from: payload) }
    }

    override func serviceExtensionTimeWillExpire() {
        // out of time: the neutral text, at once.
        Log.app.error("notification: out of time")
        delivery?.deliverNeutral()
    }

    /// The push as it came, its text neutral whatever the payload said, grouped by its chat. No
    /// badge: the server's counts every room; the app's is the inbox's, which `Delivery` counts on.
    private static func neutral(_ pushed: UNNotificationContent) -> UNNotificationContent {
        let content = UNMutableNotificationContent()
        content.body = String(localized: "New message")
        content.sound = .default
        content.userInfo = pushed.userInfo
        content.categoryIdentifier = PushNotifications.messageCategory
        if let payload = PushPayload(userInfo: pushed.userInfo) { content.threadIdentifier = payload.roomId }
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
    /// The pushed message's room; nil for a push that names none.
    private let room: String?
    private let lock = NSLock()
    /// The system's handler, taken by the first delivery, under `lock`.
    private var handler: ((UNNotificationContent) -> Void)?

    init(neutral: UNNotificationContent, room: String?, handler: @escaping (UNNotificationContent) -> Void) {
        self.neutral = neutral
        self.room = room
        self.handler = handler
    }

    /// The neutral text for a message that could not be read: it counts on the badge by its room.
    func deliverNeutral() { deliver(neutral, chat: room) }

    /// Whether this build has the filtering entitlement (`com.apple.developer.usernotifications.
    /// filtering`), which lets an extension drop a notification by handing back empty content.
    /// The entitlement cannot be read at run time on iOS: `project.yml` sets this key beside it.
    private static let filters = Bundle.main.object(forInfoDictionaryKey: "LuxFiltersNotifications") as? Bool ?? false

    /// Reads the pushed event and shows it; anything that fails shows the neutral text.
    func fill(from payload: PushPayload) async {
        do {
            // the account's stores in the App Group are closed again before the notification goes.
            guard case .read(let pushed) = try await Self.events.read(payload) else {
                Log.app.error("notification: no account is kept")
                deliverNeutral()
                return
            }
            guard let message = pushed else {
                // not to be shown: dropped where the system allows it; the badge stays as it is.
                deliver(PushNotifications.notShown(neutral, dropping: Self.filters), chat: nil)
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
            // a thread's reply opens, and is answered, in its thread.
            content.userInfo.merge(message.userInfo) { _, read in read }
            // a merged chat's rooms in one group, as the chat list shows them.
            content.threadIdentifier = message.chatId
            // history a bridge brings in (a message that came late) is quiet. Set last: the intent's
            // update makes new content.
            let shown = await Self.communication(content, message) ?? content
            deliver(message.isLate ? PushNotifications.quiet(shown) : shown, chat: message.chatId)
        } catch {
            Log.app.error("notification: \(String(describing: error), privacy: .public)")
            deliverNeutral()
        }
    }

    /// Hands `content` to the system, once: with the badge counting a message of `chat` (nil: the
    /// badge stays as it is).
    private func deliver(_ content: UNNotificationContent, chat: String?) {
        guard let handler = lock.withLock({ self.handler.take() }) else { return }
        handler(badged(content, chat: chat))
    }

    /// `content` with the app's badge after a message of `chat` in the pushed room: the inbox's
    /// count, as the app last kept it, counted on (`BadgeState`). Without a kept badge (the app
    /// has not counted one yet), the badge stays as it is.
    private func badged(_ content: UNNotificationContent, chat: String?) -> UNNotificationContent {
        guard let chat, let room, let shared = BadgeState.shared,
              let count = BadgeState.count(messageIn: room, of: chat, in: shared),
              let badged = content.mutableCopy() as? UNMutableNotificationContent else { return content }
        badged.badge = NSNumber(value: count)
        return badged.copy() as? UNNotificationContent ?? badged
    }

    /// The notification as a message from a person (their picture and name over it, the group's
    /// name for a group, Focus letting the people it allows through), when the system takes it.
    /// The picture is the sender's in a group too (who wrote), else their initials as the chat
    /// list shows them: never the app's icon. The interaction is donated first, as the system
    /// asks: content updated from an intent it has not been told of shows as the app's.
    private static func communication(_ content: UNNotificationContent, _ message: PushedMessage) async -> UNNotificationContent? {
        let picture = message.senderImage ?? Monogram.image(message.senderName, side: 120).pngData()
        let sender = INPerson(personHandle: INPersonHandle(value: message.senderName, type: .unknown), nameComponents: nil,
                              displayName: message.senderName, image: picture.map { INImage(imageData: $0) },
                              contactIdentifier: nil, customIdentifier: nil)
        let group = message.isGroup ? INSpeakableString(spokenPhrase: message.chatName) : nil
        // a group needs a second person among the recipients to show as a group.
        let intent = INSendMessageIntent(recipients: message.isGroup ? [sender, Self.me] : nil, outgoingMessageType: .outgoingMessageText,
                                         content: message.body, speakableGroupName: group,
                                         conversationIdentifier: message.chatId, serviceName: nil, sender: sender, attachments: nil)
        // a group shows its sender's picture, as a chat of two does.
        if message.isGroup, let picture {
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

/// The account, open while pushes are read. Two pushes close together share one opening (the
/// actor is re-entered while the first one awaits; a second account over the same store would
/// double the extension's memory), and the last of them closes it before its notification goes:
/// the extension is suspended once it hands a notification back, and iOS ends a process that
/// holds a lock on a file in the App Group then (0xdead10cc). The next push opens it again. The
/// work runs under a process activity, as Apple asks of an extension that writes such files.
private actor EventsHolder {
    /// What a push's read gave.
    enum Read {
        /// No account is kept.
        case noAccount
        /// The message, or nil when it is not to be shown.
        case read(PushedMessage?)
    }

    private var opening: Task<PushedEvents?, any Error>?
    /// The reads under way, over `opening`.
    private var readers = 0
    /// The last reader's close of the account: the next push opens it after.
    private var closing: Task<Void, Never>?

    func read(_ payload: PushPayload) async throws -> Read {
        await closing?.value
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Reading a pushed message")
        readers += 1
        let read: Result<Read, any Error>
        do {
            if let events = try await open() {
                read = .success(.read(try await events.read(payload)))
            } else {
                read = .success(.noAccount)
            }
        } catch {
            read = .failure(error)
        }
        readers -= 1
        if readers == 0, let opened = opening {
            opening = nil
            let close = Task {
                if case .success(let events?) = await opened.result { await events.close() }
            }
            closing = close
            await close.value
        }
        ProcessInfo.processInfo.endActivity(activity)
        return try read.get()
    }

    private func open() async throws -> PushedEvents? {
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
