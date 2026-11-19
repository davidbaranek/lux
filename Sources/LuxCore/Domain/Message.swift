import Foundation

/// One message of a chat, with how it groups with its neighbours.
public struct MessageItem: Hashable, Sendable, Identifiable {
    public enum State: Hashable, Sendable { case sending, sent, failed }
    public struct Reader: Hashable, Sendable {
        public var userId: String
        public var name: String
        public init(userId: String, name: String) { self.userId = userId; self.name = name }
    }
    public struct Reaction: Hashable, Sendable {
        public var key: String
        public var count: Int
        public var isMine: Bool
        public init(key: String, count: Int, isMine: Bool) { self.key = key; self.count = count; self.isMine = isMine }
    }
    /// The picture a message shows: a photo's thumbnail, or a video's poster.
    public struct Photo: Hashable, Sendable {
        public var ref: ImageRef
        public var width: Int
        public var height: Int
        public var isAnimated = false

        public init(ref: ImageRef, width: Int, height: Int, isAnimated: Bool = false) {
            self.ref = ref; self.width = width; self.height = height; self.isAnimated = isAnimated
        }
    }
    /// A video message: its picture is the poster (`photo`), or none.
    public struct Video: Hashable, Sendable {
        /// In seconds; 0 when the sender did not say.
        public var duration: Int
        public init(duration: Int) { self.duration = duration }
    }
    /// A photo or a video of a gallery: photos sent together show as one bubble.
    public struct AlbumItem: Hashable, Sendable {
        public var messageId: String
        public var photo: Photo
        public var video: Video?
    }
    /// A file message, or a sound (a voice message, an audio file), drawn as a row with its name.
    public struct File: Hashable, Sendable {
        public enum Kind: Hashable, Sendable { case document, audio, voice }
        public var name: String
        /// In bytes; 0 when the sender did not say.
        public var size: Int
        public var mimetype: String
        public var kind: Kind = .document
        /// A sound's length in seconds; 0 for a document or when the sender did not say.
        public var duration = 0

        public init(name: String, size: Int, mimetype: String, kind: Kind = .document, duration: Int = 0) {
            self.name = name; self.size = size; self.mimetype = mimetype; self.kind = kind; self.duration = duration
        }
    }

    public var id: String
    public var senderId: String
    public var senderName: String
    /// The sender's picture; nil when they have none.
    public var senderAvatar: ImageRef?
    public var body: String
    public var date: Date
    public var isOwn: Bool
    public var state: State
    public var photo: Photo?
    public var video: Video?
    /// Photos and videos the same person sent together, this one first: one bubble with a grid.
    /// Empty for a single photo and for anything else.
    public var album: [AlbumItem] = []
    public var file: File?
    /// While an own photo or file uploads: how much has gone, 0 to 1.
    public var uploadProgress: Double?
    public var reactions: [Reaction]
    public var isEdited: Bool
    /// The message this one answers, as its quote shows it.
    public var quote: Quote?
    /// Your own text message: it can be edited.
    public var isEditable = false
    /// Its event id once the server has it ("" before): what Saved keeps.
    public var eventId = ""
    /// The room it is in: one of a merged chat's (`ThreadModel` sets it).
    public var roomId = ""
    /// Its network, in a merged chat (where it shows on asking); nil elsewhere.
    public var network: String?
    /// The user tapped it: its full time (and network) show under it.
    public var showsDetail = false
    /// In the user's Saved list.
    public var isSaved = false
    /// Deleted for everyone (its body says so).
    public var isDeleted = false
    /// The row folds this many deleted messages, one after another, this one first ("6 deleted
    /// messages", its body); a tap shows each in its own row. 0 for a message shown on its own.
    public var deletedRun = 0
    /// Who has read the chat up to this message (others, not its sender), the earliest first.
    public var readers: [Reader] = []
    /// The first message of a day: a day separator goes above it.
    public var startsDay = true
    /// A while passed since the message before it (the same day): the time shows above it.
    public var startsTimeGap = false
    /// Bold, italic, code, quotes and links of a formatted message, in `body`'s UTF-16 offsets.
    public var styles: [TextStyle] = []
    /// The web addresses in `body`, found by the core with the rows: a formatted link's,
    /// then the addresses written as text.
    public var links: [Link] = []
    /// The post it shares from another network (a reel, a post), shown as a card under its
    /// media instead of its address.
    public var shared: SharedPost?
    /// The user unfolded its shared post's whole caption.
    public var showsWholePost = false
    /// What shows under it when it is not plain ("Edited · Sending…"), set by the core.
    public var footer: Footer?
    /// The Matrix thread it starts, summed up under it (in the chat's own timeline): a tap opens
    /// the thread.
    public var thread: ThreadSummary?

    /// A Matrix thread under its root message: how many replied, the last reply, who took part.
    public struct ThreadSummary: Hashable, Sendable {
        public struct Participant: Hashable, Sendable {
            public var userId: String
            public var name: String
            public var avatar: ImageRef?

            public init(userId: String, name: String, avatar: ImageRef? = nil) {
                self.userId = userId; self.name = name; self.avatar = avatar
            }
        }
        public var replies: Int
        /// Who wrote the last reply and what it is ("Photo"), once known.
        public var latestSender: String?
        public var latestText: String?
        public var latestDate: Date?
        /// Who replied, the last to reply first.
        public var participants: [Participant]
        /// Replies others sent since the user read the thread.
        public var unread: Int

        public init(replies: Int, latestSender: String? = nil, latestText: String? = nil, latestDate: Date? = nil,
                    participants: [Participant] = [], unread: Int = 0) {
            self.replies = replies; self.latestSender = latestSender; self.latestText = latestText
            self.latestDate = latestDate; self.participants = participants; self.unread = unread
        }
    }

    /// A post shared from another network: its address (shown and copied from the menu), its
    /// title and its caption, as the core tells them.
    public struct SharedPost: Hashable, Sendable {
        public var url: String
        public var title: String?
        public var description: String?

        public init(url: String, title: String? = nil, description: String? = nil) {
            self.url = url
            self.title = title
            self.description = description
        }

        /// The post's page, opened by a tap on its card (its title or caption).
        public var link: URL? { URL(string: url) }

        /// The address as a card names a post that tells nothing else: its site and path, without
        /// `www.`, the query or a closing slash ("instagram.com/p/abc").
        public var address: String {
            guard let parts = URLComponents(string: url), let host = parts.host else { return url }
            let site = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            let path = parts.path.hasSuffix("/") ? String(parts.path.dropLast()) : parts.path
            return site + path
        }
    }

    /// The message a reply answers: its sender (empty until known) and picture, and what it is
    /// ("hi", "Photo").
    public struct Quote: Hashable, Sendable {
        public var senderName: String
        public var text: String
        public var senderAvatar: ImageRef?

        public init(senderName: String, text: String, senderAvatar: ImageRef? = nil) {
            self.senderName = senderName
            self.text = text
            self.senderAvatar = senderAvatar
        }
    }

    /// What is not plain about a message, as the core tells it; the app words it.
    public struct Footer: Hashable, Sendable {
        public enum Status: Hashable, Sendable {
            case sending
            /// An upload's progress, 0 to 1.
            case uploading(Double)
            case failed
        }
        public var isEdited: Bool
        /// Not sent yet, or failed; nil once sent.
        public var status: Status?
    }

    public struct Link: Hashable, Sendable {
        /// In `body`'s UTF-16 offsets, as text views count.
        public var range: NSRange
        public var url: URL
    }
    /// The first of a run of messages from one sender: it shows the sender's name in a group.
    public var startsGroup = true
    /// The last of the run: its bubble gets the tail and some space after.
    public var endsGroup = true

    public init(id: String, senderId: String, senderName: String, body: String, date: Date, isOwn: Bool,
                state: State = .sent, photo: Photo? = nil, reactions: [Reaction] = [], isEdited: Bool = false, quote: Quote? = nil,
                senderAvatar: ImageRef? = nil) {
        self.senderAvatar = senderAvatar
        self.id = id
        self.senderId = senderId
        self.senderName = senderName
        self.body = body
        self.date = date
        self.isOwn = isOwn
        self.state = state
        self.photo = photo
        self.reactions = reactions
        self.isEdited = isEdited
        self.quote = quote
    }
}

extension MessageItem {
    /// It has something to open full screen or in Quick Look: a photo, a video, a file.
    public var hasMedia: Bool { photo != nil || video != nil || file != nil }

    /// Its pictures as an album's: its album's, or its own photo alone.
    var albumItems: [AlbumItem] {
        album.isEmpty ? photo.map { [AlbumItem(messageId: id, photo: $0, video: video)] } ?? [] : album
    }

    /// The messages a tap opens: an album's every photo, else this one.
    public var mediaMessageIds: [String] { album.isEmpty ? [id] : album.map(\.messageId) }
}

/// The message a reply answers, as the reply bar shows it.
public struct ReplyPreview: Sendable, Equatable {
    public var messageId: String
    public var senderName: String
    public var body: String
    public init(messageId: String, senderName: String, body: String) {
        self.messageId = messageId; self.senderName = senderName; self.body = body
    }
}

/// A Matrix thread of a chat: the replies under one of its messages, shown as a timeline of their
/// own (its root first).
public struct MatrixThread: Hashable, Sendable {
    /// The room it is in.
    public var roomId: String
    /// Its root message's event.
    public var rootEventId: String

    public init(roomId: String, rootEventId: String) {
        self.roomId = roomId
        self.rootEventId = rootEventId
    }
}

/// A Matrix thread of a room, as the chat's list of threads shows it.
public struct ListedThread: Hashable, Sendable, Identifiable {
    public var thread: MatrixThread
    public var senderName: String
    public var senderAvatar: ImageRef?
    /// What the root says ("Saturday?", "Photo").
    public var text: String
    public var date: Date
    public var summary: MessageItem.ThreadSummary
    public var id: String { thread.rootEventId }

    public init(thread: MatrixThread, senderName: String, senderAvatar: ImageRef?, text: String, date: Date,
                summary: MessageItem.ThreadSummary) {
        self.thread = thread; self.senderName = senderName; self.senderAvatar = senderAvatar
        self.text = text; self.date = date; self.summary = summary
    }

    /// When it was last active: its last reply, else its root.
    public var activity: Date { summary.latestDate ?? date }
}
