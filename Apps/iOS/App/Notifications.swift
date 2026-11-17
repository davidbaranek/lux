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
        let granted = await bestEffort("notifications: ask to notify") {
            try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        } ?? false
        guard granted else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// The token arrived: the account's server gets it.
    func registered(token: Data) {
        Task { await session.registerPusher(token: token) }
    }

    /// The app's badge: the inbox's chats with unread messages, from the chat list while the app
    /// runs. Kept in the App Group, so the notification extension counts on from it while the app
    /// is not running; whatever it counted is put right here, and as the app comes back to the
    /// front, `showBadge()`.
    func setBadge(_ state: BadgeState) {
        badge = state.count
        if let shared = BadgeState.shared { state.keep(in: shared) }
        showBadge()
    }

    /// The inbox's count as the chat list last told it; nil before it told any.
    private var badge: Int?

    /// Shows the inbox's count on the app's icon again.
    func showBadge() {
        guard let badge else { return }
        UNUserNotificationCenter.current().setBadgeCount(badge)
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        let info = notification.request.content.userInfo
        // the chat (or the thread) on screen shows the message itself.
        if let room = PushNotifications.room(of: info), session.showsMessage(of: room, thread: PushPayload(userInfo: info)?.threadRoot) {
            return []
        }
        // not its badge: the app's is the inbox's, which the list keeps.
        return [.banner, .list, .sound]
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
        if UIApplication.shared.applicationState != .active { await session.enterBackground()?.value }
    }
}
