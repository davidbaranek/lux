import Foundation

/// A message pinned in a room (`m.room.pinned_events`), as the chat's pinned bar shows it.
public struct PinnedMessage: Sendable, Hashable, Identifiable {
    public var roomId: String
    public var eventId: String
    public var senderName: String
    public var senderAvatar: ImageRef?
    /// What it is, in one line (its text, "Photo").
    public var text: String
    public var date: Date

    public var id: String { eventId }
    /// Where a jump to it goes.
    public var link: MessageLink { MessageLink(roomId: roomId, eventId: eventId) }

    public init(roomId: String, eventId: String, senderName: String, senderAvatar: ImageRef?, text: String, date: Date) {
        self.roomId = roomId; self.eventId = eventId; self.senderName = senderName; self.senderAvatar = senderAvatar
        self.text = text; self.date = date
    }
}
