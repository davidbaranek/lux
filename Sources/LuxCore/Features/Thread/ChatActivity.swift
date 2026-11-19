import Foundation

/// The open chat, at its Matrix thread if one is open, as Handoff passes it to the account's
/// other devices, where the same chat opens through the app's own navigation. It carries the room
/// and the thread's root only, never a message's content, and stays out of Spotlight and Siri's
/// suggestions: it is for Handoff alone.
public struct ChatActivity: Hashable, Sendable {
    /// The activity's type, listed in each app's `NSUserActivityTypes`; the same in both apps.
    public static let type = "\(AppIdentity.bundleId).chat"
    /// One of the chat's rooms: a merged chat opens whole from any of them.
    public var roomId: String
    /// The open Matrix thread's root event.
    public var threadRoot: String?

    public init(roomId: String, threadRoot: String? = nil) {
        self.roomId = roomId
        self.threadRoot = threadRoot
    }

    /// The chat an activity continued from another device names; nil for another kind.
    public init?(_ activity: NSUserActivity) {
        guard activity.activityType == Self.type, let room = activity.userInfo?[Key.room] as? String else { return nil }
        self.init(roomId: room, threadRoot: activity.userInfo?[Key.thread] as? String)
    }

    /// An activity for Handoff only.
    public func activity() -> NSUserActivity {
        let activity = NSUserActivity(activityType: Self.type)
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = false
        activity.isEligibleForPublicIndexing = false
        #if os(iOS)
        activity.isEligibleForPrediction = false
        #endif
        activity.requiredUserInfoKeys = [Key.room]
        var info = [Key.room: roomId]
        info[Key.thread] = threadRoot
        activity.addUserInfoEntries(from: info)
        return activity
    }

    private enum Key {
        static let room = "room", thread = "thread"
    }
}
