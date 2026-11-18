import Foundation

/// What a search found, or, before any words are typed, what was shared lately: each kind the
/// newest (or the best) first.
public struct SearchHits: Sendable, Equatable {
    public var chats: [ChatRow]
    public var messages: [FoundItem]
    /// The photos: the best first, or the newest.
    public var photos: [FoundPhoto]
    public var links: [FoundLink]
    public var files: [FoundFile]
    public var threads: [FoundThread]
    /// Why photos may be missing from these results, in words: the model downloads, photos wait
    /// to be read; nil when the photos found are all there are.
    public var photoNote: String?
    /// The words are still being looked for in what photos show (the text encoder loads): the
    /// photos found by their look follow.
    public var isLookPending = false
    public init(chats: [ChatRow] = [], messages: [FoundItem] = [], photos: [FoundPhoto] = [], links: [FoundLink] = [],
                files: [FoundFile] = [], threads: [FoundThread] = [], photoNote: String? = nil) {
        self.chats = chats; self.messages = messages; self.photos = photos; self.links = links; self.files = files
        self.threads = threads; self.photoNote = photoNote
    }

    public var isEmpty: Bool {
        chats.isEmpty && messages.isEmpty && photos.isEmpty && links.isEmpty && files.isEmpty && threads.isEmpty
    }
}

/// A kind of what chats shared, listed on its own page from search (as Messages lists "Photos",
/// "Links"): each with its button over the results.
public enum SearchKind: String, CaseIterable, Sendable, Hashable {
    case photos, links, files, threads

    public var title: String {
        switch self {
        case .photos: String(localized: "Photos")
        case .links: String(localized: "Links")
        case .files: String(localized: "Files")
        case .threads: String(localized: "Threads")
        }
    }

    /// Its SF Symbol.
    public var symbol: String {
        switch self {
        case .photos: "photo.on.rectangle"
        case .links: "link"
        case .files: "doc"
        case .threads: "bubble.left.and.text.bubble.right"
        }
    }

    /// How many of it the results show before "Show All".
    public var preview: Int {
        switch self {
        case .photos: 8
        case .links, .files, .threads: 3
        }
    }

    /// How many of it one page of its own list loads.
    public var page: Int {
        switch self {
        case .photos: 60
        case .links, .files, .threads: 40
        }
    }
}

extension SearchHits {
    /// What the status line over the results says: how far the message index is, and why photos
    /// may be missing.
    public func note(index: SearchIndexer.Progress?) -> String? {
        let notes = [index?.note, photoNote].compactMap(\.self)
        return notes.isEmpty ? nil : notes.joined(separator: "\n")
    }

    /// How many of `kind` were found.
    public func count(of kind: SearchKind) -> Int {
        switch kind {
        case .photos: photos.count
        case .links: links.count
        case .files: files.count
        case .threads: threads.count
        }
    }

    /// These and `more` of `kind`, the next page of its list.
    public mutating func append(_ more: SearchHits, of kind: SearchKind) {
        switch kind {
        case .photos: photos += more.photos.filter { photo in !photos.contains { $0.id == photo.id } }
        case .links: links += more.links.filter { link in !links.contains { $0.id == link.id } }
        case .files: files += more.files.filter { file in !files.contains { $0.id == file.id } }
        case .threads: threads += more.threads.filter { thread in !threads.contains { $0.id == thread.id } }
        }
    }
}

/// A web address a message sent, with its chat.
public struct FoundLink: Sendable, Hashable, Identifiable {
    /// Its message's event id and the address: a message may send several.
    public var id: String { "\(eventId) \(url)" }
    public var eventId: String
    /// Its message's room (one of a merged chat's).
    public var roomId: String
    public var chat: ChatRow
    public var senderName: String
    public var url: String
    /// The message's text.
    public var text: String
    public var date: Date
    public var isOwn: Bool

    public init(eventId: String, roomId: String, chat: ChatRow, senderName: String, url: String, text: String, date: Date,
                isOwn: Bool) {
        self.eventId = eventId; self.roomId = roomId; self.chat = chat; self.senderName = senderName; self.url = url; self.text = text
        self.date = date; self.isOwn = isOwn
    }

    /// Its host without "www." ("mapy.cz"), or the address when it has none.
    public var host: String {
        guard let host = URL(string: url)?.host() else { return url }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// A file a message sent, with its chat.
public struct FoundFile: Sendable, Hashable, Identifiable {
    /// Its event id.
    public var id: String
    public var roomId: String
    public var chat: ChatRow
    public var senderName: String
    public var name: String
    public var size: UInt64?
    public var mimetype: String?
    public var date: Date
    public var isOwn: Bool

    public init(id: String, roomId: String, chat: ChatRow, senderName: String, name: String, size: UInt64?,
                mimetype: String?, date: Date, isOwn: Bool) {
        self.id = id; self.roomId = roomId; self.chat = chat; self.senderName = senderName; self.name = name
        self.size = size; self.mimetype = mimetype; self.date = date; self.isOwn = isOwn
    }

    /// "1,2 MB · Anna · 3. 5." under the name.
    public var detail: String {
        [size.map { ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .file) },
         isOwn ? String(localized: "You") : senderName,
         date.formatted(date: .abbreviated, time: .omitted)]
            .compactMap(\.self).joined(separator: " · ")
    }
}

/// A thread, with its chat: its root and its newest reply.
public struct FoundThread: Sendable, Hashable, Identifiable {
    /// Its root's event id.
    public var id: String
    public var roomId: String
    public var chat: ChatRow
    /// Who started it and what they wrote, when the index holds its root (a text message).
    public var rootSender: String?
    public var rootText: String?
    public var replies: Int
    public var latestSender: String
    public var latestText: String
    public var latest: Date

    public init(id: String, roomId: String, chat: ChatRow, rootSender: String?, rootText: String?, replies: Int,
                latestSender: String, latestText: String, latest: Date) {
        self.id = id; self.roomId = roomId; self.chat = chat; self.rootSender = rootSender; self.rootText = rootText
        self.replies = replies; self.latestSender = latestSender; self.latestText = latestText; self.latest = latest
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
        case .looks, .listed: photo
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
    /// Listed with the others, the newest first: no words were searched.
    case listed
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
    /// Its room (one of a merged chat's).
    public var roomId: String
    public var chat: ChatRow
    public var senderName: String
    public var body: String
    public var date: Date
    public var isOwn: Bool
    /// The found words in `body`, in UTF-16 offsets.
    public var matches: [NSRange]
    public init(id: String, roomId: String, chat: ChatRow, senderName: String, body: String, date: Date, isOwn: Bool,
                matches: [NSRange] = []) {
        self.id = id; self.roomId = roomId; self.chat = chat; self.senderName = senderName; self.body = body; self.date = date; self.isOwn = isOwn
        self.matches = matches
    }
}

/// One walk back through a chat's text messages and photos, for the search index.
public struct IndexHistoryPage: Sendable {
    public var messages: [IndexedMessage]
    public var images: [IndexedImage]
    public var files: [IndexedFile]
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
    public init(messages: [IndexedMessage], images: [IndexedImage] = [], files: [IndexedFile] = [], reachedStart: Bool,
                removed: [String] = [], deletedUntil: Date? = nil, reachedSince: Bool = false, older: String? = nil) {
        self.messages = messages; self.images = images; self.files = files; self.reachedStart = reachedStart; self.removed = removed
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
    /// The web addresses in it.
    public var links: [String]
    /// The thread it replies in: its root's event id.
    public var thread: String?
    public var date: Date
    public var isOwn: Bool

    public init(eventId: String, roomId: String, senderName: String, body: String, links: [String] = [], thread: String? = nil,
                date: Date, isOwn: Bool) {
        self.eventId = eventId; self.roomId = roomId; self.senderName = senderName
        self.body = body; self.links = links; self.thread = thread; self.date = date; self.isOwn = isOwn
    }
}

/// A file the search index keeps: its name, to find it by, and where it is.
public struct IndexedFile: Sendable, Equatable {
    public var eventId: String
    public var roomId: String
    public var senderName: String
    public var name: String
    public var size: UInt64?
    public var mimetype: String?
    public var date: Date
    public var isOwn: Bool
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

/// Where a search result leads: its chat (at its message), its thread over its chat, or a link's
/// page (its message stays a menu's "Show in Chat").
public enum SearchTarget: Sendable, Hashable {
    case chat(ChatRow, focus: MessageLink?)
    case thread(ChatRow, MatrixThread)
    case link(URL)
}

extension FoundItem {
    public var target: SearchTarget { .chat(chat, focus: MessageLink(roomId: roomId, eventId: id)) }
}

extension FoundPhoto {
    public var target: SearchTarget { .chat(chat, focus: MessageLink(roomId: roomId, eventId: id)) }
}

extension FoundFile {
    public var target: SearchTarget { .chat(chat, focus: MessageLink(roomId: roomId, eventId: id)) }
}

extension FoundThread {
    public var target: SearchTarget { .thread(chat, MatrixThread(roomId: roomId, rootEventId: id)) }

    /// "Anna: Kdo jde na výlet?", or the chat's name when the index has no root text.
    public var title: String {
        guard let rootText, !rootText.isEmpty else { return chat.name }
        return rootSender.map { "\($0): \(rootText)" } ?? rootText
    }

    /// "4 replies · Petr: Jdu taky".
    public var detail: String {
        String(localized: "\(replies) replies") + " · \(latestSender): \(latestText)"
    }
}

extension FoundLink {
    /// Its page; the message, when the address is no web address a browser opens.
    public var target: SearchTarget {
        if let url = URL(string: url), url.scheme != nil { .link(url) } else { message }
    }

    /// Its message in its chat.
    public var message: SearchTarget { .chat(chat, focus: MessageLink(roomId: roomId, eventId: eventId)) }
}
