import Foundation

/// What a search found.
public struct SearchHits: Sendable, Equatable {
    public var chats: [ChatRow]
    public var messages: [FoundItem]
    public init(chats: [ChatRow] = [], messages: [FoundItem] = []) { self.chats = chats; self.messages = messages }
}

/// A message a search found, with its chat.
public struct FoundItem: Sendable, Hashable, Identifiable {
    public var id: String
    public var chat: ChatRow
    public var senderName: String
    public var body: String
    public var date: Date
    public var isOwn: Bool
    /// The found words in `body`, in UTF-16 offsets.
    public var matches: [NSRange]
    public init(id: String, chat: ChatRow, senderName: String, body: String, date: Date, isOwn: Bool, matches: [NSRange] = []) {
        self.id = id; self.chat = chat; self.senderName = senderName; self.body = body; self.date = date; self.isOwn = isOwn
        self.matches = matches
    }
}

/// One walk back through a chat's text messages, for the search index.
public struct TextHistoryPage: Sendable {
    public var messages: [IndexedMessage]
    /// The chat has no older messages.
    public var reachedStart: Bool
    /// The event ids of the messages deleted meanwhile, which the index may hold from before.
    public var removed: [String]
    /// The chat was deleted when its newest message was this one's: the index forgets what it
    /// holds up to it (none of it is among `messages`).
    public var deletedUntil: Date?
    public init(messages: [IndexedMessage], reachedStart: Bool, removed: [String] = [], deletedUntil: Date? = nil) {
        self.messages = messages; self.reachedStart = reachedStart; self.removed = removed; self.deletedUntil = deletedUntil
    }
}

extension FoundItem {
    /// Who wrote it, before the text in the row's preview ("You: ", "Anna: ", or nothing).
    private var previewPrefix: String {
        isOwn ? "You: " : (senderName.isEmpty || !chat.isGroup ? "" : senderName + ": ")
    }

    /// The found words in the row's preview (`row`).
    public var previewMatches: [NSRange] {
        let shift = previewPrefix.utf16.count
        return matches.map { NSRange(location: $0.location + shift, length: $0.length) }
    }

    /// The found message as a chat-list row: its chat's name and picture, and the message as the preview.
    public var row: ChatRow {
        var row = chat
        row.id = id
        row.preview = previewPrefix + body
        row.date = date
        row.unreadCount = 0
        row.isMarkedUnread = false
        return row
    }
}

/// A message the search index keeps.
public struct IndexedMessage: Sendable, Equatable {
    public var eventId: String
    public var roomId: String
    public var senderName: String
    public var body: String
    public var date: Date
    public var isOwn: Bool

    public init(eventId: String, roomId: String, senderName: String, body: String, date: Date, isOwn: Bool) {
        self.eventId = eventId; self.roomId = roomId; self.senderName = senderName
        self.body = body; self.date = date; self.isOwn = isOwn
    }
}

/// A message a search found: an excerpt of its text around the words, and where they are in it.
public struct IndexHit: Sendable, Equatable {
    public var eventId: String
    public var roomId: String
    public var senderName: String
    public var excerpt: String
    /// The found words in `excerpt`, in UTF-16 offsets.
    public var matches: [NSRange]
    public var date: Date
    public var isOwn: Bool
}

/// How far the index has read one chat.
public struct IndexedChat: Sendable, Equatable {
    /// The newest message indexed.
    public var newest: Date
    /// Its history is indexed as far back as the index goes (or to its start).
    public var complete: Bool
}
