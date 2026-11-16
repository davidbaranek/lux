import Foundation

/// What a search found.
public struct SearchHits: Sendable, Equatable {
    public var chats: [ChatRow]
    public var messages: [FoundItem]
    /// Photos, when photo search is on: the best first.
    public var photos: [FoundPhoto]
    /// Why photos may be missing from these results, in words: the model downloads, photos wait
    /// to be read, the look is still being looked for; nil when the photos found are all there are.
    public var photoNote: String?
    public init(chats: [ChatRow] = [], messages: [FoundItem] = [], photos: [FoundPhoto] = [], photoNote: String? = nil) {
        self.chats = chats; self.messages = messages; self.photos = photos; self.photoNote = photoNote
    }
}

/// Which results a search shows: all of them, the text ones (chats by name and messages), or
/// the photos.
public enum SearchScope: Int, CaseIterable, Sendable {
    case all, text, images

    public var title: String {
        switch self {
        case .all: String(localized: "All")
        case .text: String(localized: "Text")
        case .images: String(localized: "Images")
        }
    }
}

extension SearchHits {
    /// The hits the scope shows.
    /// What the status line under the results says: how far the message index is, and why photos
    /// may be missing (not under Text, which shows none).
    public func note(index: SearchIndexer.Progress?, scope: SearchScope) -> String? {
        let notes = [index?.note, scope == .text ? nil : photoNote].compactMap(\.self)
        return notes.isEmpty ? nil : notes.joined(separator: "\n")
    }

    public func scoped(_ scope: SearchScope) -> SearchHits {
        switch scope {
        case .all: self
        case .text: SearchHits(chats: chats, messages: messages)
        case .images: SearchHits(photos: photos, photoNote: photoNote)
        }
    }
}

/// A photo a search found, with its chat and why.
public struct FoundPhoto: Sendable, Hashable, Identifiable {
    /// Its event's id.
    public var id: String
    /// Its room (one of a merged chat's).
    public var roomId: String
    public var chat: ChatRow
    public var senderName: String
    public var date: Date
    public var isOwn: Bool
    public var reason: PhotoReason

    public init(id: String, roomId: String, chat: ChatRow, senderName: String, date: Date, isOwn: Bool, reason: PhotoReason) {
        self.id = id; self.roomId = roomId; self.chat = chat; self.senderName = senderName; self.date = date; self.isOwn = isOwn
        self.reason = reason
    }

    /// Its thumbnail, by its event; named by it (letters and digits only: the demo draws it as a
    /// file of that name).
    public var image: ImageRef { .foundPhoto(roomId: roomId, eventId: id) }
}

extension FoundPhoto {
    /// The found photo as a chat-list row: its chat's name and picture, and why it was found as
    /// the preview ("Photo · Celkem 1 250 Kč").
    public var row: ChatRow {
        var row = chat
        row.id = id
        let photo = String(localized: "Photo")
        row.preview = switch reason {
        case .words(let excerpt, _), .nearby(let excerpt, _): "\(photo) · \(excerpt)"
        case .looks: photo
        }
        row.date = date
        row.unreadCount = 0
        row.isMarkedUnread = false
        return row
    }
}

/// Why a search found a photo.
public enum PhotoReason: Sendable, Hashable {
    /// Its caption or the words in it: those around the found ones, and where they are (UTF-16).
    case words(String, matches: [NSRange])
    /// A message sent near it: its words around the found ones.
    case nearby(String, matches: [NSRange])
    /// It looks like what the words say.
    case looks
}

/// A photo the search index keeps: where it is and who sent it.
public struct IndexedImage: Sendable, Equatable {
    public var eventId: String
    public var roomId: String
    public var senderName: String
    /// The words sent with it; empty when none.
    public var caption: String
    public var date: Date
    public var isOwn: Bool

    public init(eventId: String, roomId: String, senderName: String, caption: String, date: Date, isOwn: Bool) {
        self.eventId = eventId; self.roomId = roomId; self.senderName = senderName
        self.caption = caption; self.date = date; self.isOwn = isOwn
    }
}

/// A photo the search index found: its event, chat and why.
public struct ImageHit: Sendable, Equatable {
    public var eventId: String
    public var roomId: String
    public var senderName: String
    public var date: Date
    public var isOwn: Bool
    public var reason: PhotoReason
}

/// What was read in a photo, for the index.
public struct PhotoRead: Sendable, Equatable {
    public var eventId: String
    /// Who read it, with the readers' versions: a newer reader reads it again.
    public var reader: String
    /// The words in it.
    public var words: String
    /// Its unit embedding; nil when the reader has no model.
    public var embedding: [Float]?
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

/// One walk back through a chat's text messages and photos, for the search index.
public struct IndexHistoryPage: Sendable {
    public var messages: [IndexedMessage]
    public var images: [IndexedImage]
    /// The chat has no older messages.
    public var reachedStart: Bool
    /// The event ids of the messages deleted meanwhile, which the index may hold from before.
    public var removed: [String]
    /// The chat was deleted when its newest message was this one's: the index forgets what it
    /// holds up to it (none of it is among `messages`).
    public var deletedUntil: Date?
    /// The walk went back as far as it was asked.
    public var reachedSince: Bool
    /// Where a walk further back goes on from, when the pages ran out first.
    public var older: String?
    public init(messages: [IndexedMessage], images: [IndexedImage] = [], reachedStart: Bool, removed: [String] = [],
                deletedUntil: Date? = nil, reachedSince: Bool = false, older: String? = nil) {
        self.messages = messages; self.images = images; self.reachedStart = reachedStart; self.removed = removed
        self.deletedUntil = deletedUntil; self.reachedSince = reachedSince; self.older = older
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
    /// Its history is indexed to its start.
    public var complete: Bool
    /// How far back it is indexed, when not to its start.
    public var oldest: Date?
    /// Where a read further back goes on from; none: from the newest.
    public var older: String?

    public init(newest: Date, complete: Bool, oldest: Date? = nil, older: String? = nil) {
        self.newest = newest; self.complete = complete; self.oldest = oldest; self.older = older
    }
}

/// How far back search reads each chat's history, as Settings has it. Reading back further reads
/// on from where it stopped; reading back less keeps what was read.
public enum SearchHistory: String, CaseIterable, Sendable {
    case month, threeMonths, year, all

    public var title: String {
        switch self {
        case .month: String(localized: "1 Month")
        case .threeMonths: String(localized: "3 Months")
        case .year: String(localized: "1 Year")
        case .all: String(localized: "All")
        }
    }

    /// The oldest message it reads, from `now`.
    public func since(_ now: Date) -> Date {
        let days: Double? = switch self {
        case .month: 31
        case .threeMonths: 90
        case .year: 365
        case .all: nil
        }
        return days.map { now.addingTimeInterval(-$0 * 24 * 3600) } ?? .distantPast
    }
}
