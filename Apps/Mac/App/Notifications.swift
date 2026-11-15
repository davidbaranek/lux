import AppKit
import LuxCore
import UserNotifications

/// The Mac's notifications of new messages, while the app runs (it usually does): the sync brings
/// them, the core keeps the ones that notify (noisy, from others, new and unread, each once), and
/// this shows them as the iPhone shows pushed ones: the chat's name over the sender and text,
/// grouped by chat (a merged chat's rooms as one), with Reply and Mark as Read. None for the chat
/// on screen while its window has the focus. The only delegate of the notification center: the
/// reminders' notifications come here too.
///
/// Nothing comes while the app is not running: a push to a notification service extension would
/// need the session's Keychain item and the store shared with an extension (see
/// `docs/architecture.md`).
@MainActor
final class MacNotifications: NSObject, @MainActor UNUserNotificationCenterDelegate {
    private let session: Session
    /// Opens a chat by one of its rooms, at its Matrix thread (by its root) if given.
    var openChat: ((_ room: String, _ thread: String?) -> Void)?
    /// Whether the chat (or the thread, by its root) on screen is in the focused window: its
    /// messages notify nothing.
    var isShowing: (_ room: String, _ thread: String?) -> Bool = { _, _ in false }
    private var following: Task<Void, Never>?

    init(session: Session) {
        self.session = session
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories(PushNotifications.categories)
    }

    /// Signed in: asks once to show notifications, then shows the sync's new messages until
    /// `stop`. The demo has no server: nothing comes.
    func start() {
        guard following == nil else { return }
        following = Task { [weak self, session] in
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            for await message in await session.liveNotifications() {
                self?.show(message)
            }
        }
    }

    /// Signed out: no more notifications, none left over, no badge.
    func stop() {
        following?.cancel()
        following = nil
        let center = UNUserNotificationCenter.current()
        center.removeAllDeliveredNotifications()
        setBadge(0)
    }

    /// The Dock's badge: the inbox's unread chats.
    func setBadge(_ count: Int) {
        NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
    }

    private func show(_ message: PushedMessage) {
        if NSApp.isActive, isShowing(message.roomId, message.threadRoot) { return }
        let content = UNMutableNotificationContent()
        content.title = message.title
        content.subtitle = message.subtitle
        content.body = message.body
        content.sound = .default
        content.threadIdentifier = message.chatId
        content.categoryIdentifier = PushNotifications.messageCategory
        // as a push carries them: the same actions answer both.
        content.userInfo = message.userInfo
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: message.eventId, content: content, trigger: nil))
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        let info = notification.request.content.userInfo
        // the chat (or the thread) in front shows the message itself.
        if let room = PushNotifications.room(of: info), NSApp.isActive, isShowing(room, PushPayload(userInfo: info)?.threadRoot) { return [] }
        return [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let action = NotificationAction(response) else { return }
        await handle(action)
    }

    private func handle(_ action: NotificationAction) async {
        if case .open(let room, let thread) = action {
            NSApp.activate()
            openChat?(room, thread)
            return
        }
        await session.answer(action)
    }
}
