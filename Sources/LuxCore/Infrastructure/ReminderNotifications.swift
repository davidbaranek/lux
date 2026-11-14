import Foundation
import UserNotifications

/// The reminders as local notifications on this device: one per chat, at its time, kept in step
/// with the account's reminders (which the other devices schedule for themselves).
@MainActor
final class ReminderNotifications {
    private var scheduled: [String: Date] = [:]
    /// Asked for only once there is a reminder: a process with no app bundle (the tests) has none.
    private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }
    private static let prefix = "reminder:"

    /// Asks once to show notifications; the first reminder the user sets asks.
    func requestPermission() async {
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    /// Schedules the reminders that are new or moved and removes those that went.
    func sync(_ reminders: [(roomId: String, name: String, date: Date)]) {
        guard !reminders.isEmpty || !scheduled.isEmpty else { return }
        let wanted = Dictionary(reminders.map { ($0.roomId, ($0.date, $0.name)) }, uniquingKeysWith: { first, _ in first })
        let gone = scheduled.keys.filter { wanted[$0] == nil }
        if !gone.isEmpty { center.removePendingNotificationRequests(withIdentifiers: gone.map { Self.prefix + $0 }) }
        for (roomId, (date, name)) in wanted where scheduled[roomId] != date && date > .now {
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Reply to \(name)")
            content.body = String(localized: "You asked to be reminded.")
            content.sound = .default
            content.userInfo = ["roomId": roomId]
            let trigger = UNCalendarNotificationTrigger(dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date),
                                                        repeats: false)
            center.add(UNNotificationRequest(identifier: Self.prefix + roomId, content: content, trigger: trigger))
        }
        scheduled = wanted.mapValues(\.0)
    }
}
