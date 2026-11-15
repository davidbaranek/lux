import LuxCore
import UIKit
import UserNotifications

/// The app's side of notifications: asking to show them once signed in, the push token for the
/// account's server, and what the user does with a notification (open its chat, reply, mark it
/// read), the app opening the account for it if it was not running. The only delegate of the
/// notification center: the reminders' notifications come here too.
@MainActor
final class Notifications: NSObject, @MainActor UNUserNotificationCenterDelegate {
    private let session: Session
    /// Opens a chat by one of its rooms, at its Matrix thread (by its root) if given; set once
    /// the chat list shows.
    var openChat: ((_ room: String, _ thread: String?) -> Void)? {
        didSet {
            guard let openChat, let waiting = chatToOpen else { return }
            chatToOpen = nil
            openChat(waiting.room, waiting.thread)
        }
    }
    /// A chat tapped before the list was there to open it.
    private var chatToOpen: (room: String, thread: String?)?

    init(session: Session) {
        self.session = session
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories(PushNotifications.categories)
    }

    /// Signed in: asks once to show notifications (the system asks the user only the first
    /// time), then registers for pushes; each launch registers again, as the token may change.
    func enable() async {
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        guard granted else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// The token arrived: the account's server gets it.
    func registered(token: Data) {
        Task { await session.registerPusher(token: token) }
    }

    /// The app's badge: the chats with unread messages, from the chat list while the app runs.
    func setBadge(_ count: Int) {
        UNUserNotificationCenter.current().setBadgeCount(count)
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        let info = notification.request.content.userInfo
        // the chat (or the thread) on screen shows the message itself.
        if let room = PushNotifications.room(of: info), session.showsMessage(of: room, thread: PushPayload(userInfo: info)?.threadRoot) {
            return []
        }
        return [.banner, .list, .sound, .badge]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let action = NotificationAction(response) else { return }
        await handle(action)
    }

    private func handle(_ action: NotificationAction) async {
        if case .open(let room, let thread) = action {
            if let openChat { openChat(room, thread) } else { chatToOpen = (room, thread) }
            return
        }
        await session.answer(action)
        // the app may be suspended right after: the sync stops again when no scene is in front.
        if UIApplication.shared.applicationState != .active { session.enterBackground() }
    }
}
