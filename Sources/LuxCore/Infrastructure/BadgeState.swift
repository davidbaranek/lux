import Foundation
import Synchronization

/// The app's badge while the app is not running: the inbox's chats with unread messages, as the
/// app last counted them, kept up by the notification extension. The app writes it each time it
/// sets the badge (it alone composes the inbox); the extension counts a notified message by
/// `count(messageIn:of:)`, and the app puts everything right as soon as it runs.
///
/// Kept in the App Group's defaults, small and without a lock held across processes, so iOS never
/// ends a suspended app for holding a shared file (0xdead10cc).
public struct BadgeState: Equatable, Sendable {
    /// The inbox's chats with unread messages that are not muted.
    public private(set) var count: Int
    /// The chats counted, by their ids and a merged chat's rooms: a message in one keeps the count.
    public private(set) var counted: Set<String>
    /// The rooms whose messages the inbox does not count (archived, of low priority, muted).
    public let uncounted: Set<String>

    /// No badge: signed out.
    public static let empty = BadgeState(count: 0, counted: [], uncounted: [])

    public init(count: Int, counted: Set<String>, uncounted: Set<String>) {
        self.count = count
        self.counted = counted
        self.uncounted = uncounted
    }

    /// The badge after a message in `room` of the chat `chat` (the room's own id when the chat is
    /// not known): the same for a chat already counted and for a room the inbox does not count;
    /// one more for any other (a read chat of the inbox, or one the app has not seen: a new chat or
    /// an invite, which come to the inbox), which counts from then on.
    public mutating func count(messageIn room: String, of chat: String) -> Int {
        if counted.contains(chat) || counted.contains(room) || uncounted.contains(room) { return count }
        count += 1
        counted.formUnion([chat, room])
        return count
    }

    // MARK: Kept in the App Group

    /// The App Group's defaults, shared by the app and its notification extension; nil where
    /// there is no group (an unsigned build).
    public static var shared: UserDefaults? { UserDefaults(suiteName: AppIdentity.appGroup) }

    /// One read and write at a time in this process: the extension may count two notifications
    /// at once.
    private static let lock = Mutex(())

    private static let key = "badge"

    /// The badge as last kept in `defaults`; nil before the app kept one.
    public static func kept(in defaults: UserDefaults) -> BadgeState? {
        lock.withLock { _ in read(defaults) }
    }

    /// Keeps the badge in `defaults`, as the app counted it.
    public func keep(in defaults: UserDefaults) {
        Self.lock.withLock { _ in write(defaults) }
    }

    /// Counts a message in `room` of `chat` on the badge kept in `defaults` and keeps the result;
    /// nil, and nothing kept, before the app kept a badge.
    public static func count(messageIn room: String, of chat: String, in defaults: UserDefaults) -> Int? {
        lock.withLock { _ in
            guard var state = read(defaults) else { return nil }
            let count = state.count(messageIn: room, of: chat)
            state.write(defaults)
            return count
        }
    }

    private static func read(_ defaults: UserDefaults) -> BadgeState? {
        guard let kept = defaults.dictionary(forKey: key), let count = kept["count"] as? Int,
              let counted = kept["counted"] as? [String], let uncounted = kept["uncounted"] as? [String] else { return nil }
        return BadgeState(count: count, counted: Set(counted), uncounted: Set(uncounted))
    }

    private func write(_ defaults: UserDefaults) {
        defaults.set(["count": count, "counted": Array(counted), "uncounted": Array(uncounted)], forKey: Self.key)
    }
}
