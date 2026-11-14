import Foundation
import LuxBindings

/// A chat's thread in the Rust core (`lux_core::thread`, through `lux-ffi`): the view model
/// object, and its listener's frames as Swift values, in order. Rows are mapped to
/// `MessageItem`s on the core's thread, so the main actor only applies them. The generated
/// types stay in this file.
public final class ThreadCore: Sendable {
    private let view: CoreThread
    /// The thread's events as they come, one per frame at most.
    let events: AsyncStream<Event>

    enum Event: Sendable {
        case update(Batch)
        /// Files the user sent: the platform prepares and uploads them.
        case upload(files: [URL], roomId: String, caption: String?, replyTo: String?)
        case failed(AccountFailure)
    }

    /// One frame: the rows' changes, and the state when it changed.
    struct Batch: Sendable {
        var rows: [RowChange]
        var state: State?
    }

    /// A change to the rows, as the core's `VectorDiff`.
    enum RowChange: Sendable {
        case append([MessageItem])
        case clear
        case pushFront(MessageItem)
        case pushBack(MessageItem)
        case popFront
        case popBack
        case insert(Int, MessageItem)
        case set(Int, MessageItem)
        case remove(Int)
        case truncate(Int)
        case reset([MessageItem])
    }

    struct State: Sendable, Equatable {
        var isLoading: Bool
        var canLoadOlder: Bool
        var isAtStart: Bool
        var firstUnread: String?
        var needsReadReceipt: Bool
        var typists: [Typist]
        var shownRoom: String?
        var sendRoom: String
        var mode: ThreadModel.ComposerMode
        var pendingFiles: [URL]
        var canSendLater: Bool
    }

    /// Opens the thread of `row` with `open`.
    fileprivate init(row: ChatRow, readReceipts: ReadReceipts, open: (CoreThreadOpening, CoreThreadListener) -> CoreThread) {
        let (events, continuation) = AsyncStream<Event>.makeStream()
        self.events = events
        let opening = CoreThreadOpening(chatId: row.id, rooms: row.chatRooms.map { CoreThreadRoom(id: $0.id, network: $0.network) },
                                    defaultRoom: row.defaultRoom ?? row.chatRooms[0].id, listedUnread: row.isUnread,
                                    readReceipts: CoreReadReceipts(readReceipts), timeZone: TimeZone.current.identifier)
        view = open(opening, Listener(continuation))
    }

    // MARK: Intents

    func loadOlder() { view.loadOlder() }
    func jumpToReplied(_ messageId: String) async -> String? { await view.jumpToReplied(messageId: messageId) }
    func jumpToEvent(_ eventId: String) async -> String? { await view.jumpToEvent(eventId: eventId) }
    func firstUnread() async -> String? { await view.firstUnread() }
    func loaded() async { await view.loaded() }
    func toggleDetail(_ messageId: String) { view.toggleDetail(messageId: messageId) }
    func togglePost(_ messageId: String) { view.togglePost(messageId: messageId) }
    func show(room: String?) { view.showRoom(roomId: room) }
    func reply(to messageId: String) { view.reply(messageId: messageId) }
    func edit(_ messageId: String) { view.edit(messageId: messageId) }
    func cancelMode() { view.cancelMode() }
    func send(_ text: String, via room: String?) { view.send(text: text, viaRoomId: room) }
    func sendLater(_ text: String, at date: Date) async throws { try await worded { try await view.sendLater(text: text, at: date) } }
    func attach(_ files: [URL]) { view.attach(files: files.map(\.path)) }
    func removePending(_ file: URL) { view.removePending(file: file.path) }
    func toggleReaction(_ key: String, on messageId: String) { view.toggleReaction(messageId: messageId, key: key) }
    func delete(_ messageId: String) { view.delete(messageId: messageId) }
    func retry(_ messageId: String) { view.retry(messageId: messageId) }
    func discard(_ messageId: String) { view.discard(messageId: messageId) }
    func forward(_ messageId: String, to chatId: String) { view.forward(messageId: messageId, targetChatId: chatId) }
    func save(_ messageId: String) { view.save(messageId: messageId) }
    func unsave(_ messageId: String) { view.unsave(messageId: messageId) }
    func didReadLatest() { view.didReadLatest() }
    func sendReadReceipt() { view.sendReadReceipt() }
    func set(readReceipts: ReadReceipts) { view.setReadReceipts(receipts: CoreReadReceipts(readReceipts)) }
    func watchTyping() { view.watchTyping() }
    func stopWatchingTyping() { view.stopWatchingTyping() }
    func composerChanged(_ text: String) { view.composerChanged(text: text) }
    func loadDraft() async -> String { await view.loadDraft() }
    func saveDraft(_ text: String) { view.saveDraft(text: text) }
}

extension RustAccount {
    /// A chat's thread: its view model in the core, following its rooms' timelines (they stay
    /// open while it lives), presenting its rows, deciding what the composer sends.
    func openThread(row: ChatRow, readReceipts: ReadReceipts) -> ThreadCore {
        ThreadCore(row: row, readReceipts: readReceipts) { account.openThread(opening: $0, listener: $1) }
    }
}

// MARK: The listener

/// Passes the core's frames on, mapped, in order; ends the stream when the thread goes.
private final class Listener: CoreThreadListener {
    private let continuation: AsyncStream<ThreadCore.Event>.Continuation

    init(_ continuation: AsyncStream<ThreadCore.Event>.Continuation) { self.continuation = continuation }
    deinit { continuation.finish() }

    func onUpdate(update: CoreThreadUpdate) {
        let state = Signposts.thread.beginInterval("map")
        let batch = ThreadCore.Batch(rows: update.rows.map(ThreadCore.RowChange.init), state: update.state.map(ThreadCore.State.init))
        Signposts.thread.endInterval("map", state, "\(update.rows.count) changes")
        continuation.yield(.update(batch))
    }

    func onUpload(upload: CoreUpload) {
        continuation.yield(.upload(files: upload.files.map { URL(fileURLWithPath: $0) }, roomId: upload.roomId, caption: upload.caption,
                                   replyTo: upload.replyTo))
    }

    func onError(error: CoreAccountError) { continuation.yield(.failed(AccountFailure(error))) }
}

// MARK: Mappings

private extension CoreReadReceipts {
    init(_ receipts: ReadReceipts) {
        self = switch receipts {
        case .automatic: .automatic
        case .manual: .manual
        }
    }
}

private extension ThreadCore.RowChange {
    init(_ diff: CoreThreadRowDiff) {
        self = switch diff {
        case .append(let values): .append(values.map(MessageItem.init))
        case .clear: .clear
        case .pushFront(let value): .pushFront(MessageItem(value))
        case .pushBack(let value): .pushBack(MessageItem(value))
        case .popFront: .popFront
        case .popBack: .popBack
        case .insert(let index, let value): .insert(Int(index), MessageItem(value))
        case .set(let index, let value): .set(Int(index), MessageItem(value))
        case .remove(let index): .remove(Int(index))
        case .truncate(let length): .truncate(Int(length))
        case .reset(let values): .reset(values.map(MessageItem.init))
        }
    }
}

private extension ThreadCore.State {
    init(_ state: CoreThreadState) {
        let mode: ThreadModel.ComposerMode = switch state.mode {
        case .message: .message
        case .reply(let target):
            .reply(ReplyPreview(messageId: target.messageId, senderName: target.isOwn ? String(localized: "You") : target.senderName,
                                body: target.kind.map(PreviewLine.body) ?? ""))
        case .edit(let messageId, let original): .edit(messageId: messageId, original: original)
        }
        self.init(isLoading: state.isLoading, canLoadOlder: state.canLoadOlder, isAtStart: state.isAtStart, firstUnread: state.firstUnread,
                  needsReadReceipt: state.needsReadReceipt,
                  typists: state.typists.map { Typist(name: $0.name, avatar: $0.avatar.map { .person(url: $0) }) },
                  shownRoom: state.shownRoom, sendRoom: state.sendRoom, mode: mode,
                  pendingFiles: state.pendingFiles.map { URL(fileURLWithPath: $0) }, canSendLater: state.canSendLater)
    }
}

private extension MessageItem {
    /// A row: its message, with how it shows (its album's pictures, its run, what is above and
    /// under it, its room and network, its details).
    init(_ row: CoreThreadRow) {
        self.init(row.message, roomId: row.roomId)
        if !row.albumRest.isEmpty {
            album = albumItems + row.albumRest.flatMap { MessageItem($0, roomId: row.roomId).albumItems }
        }
        network = row.network
        startsGroup = row.startsRun
        endsGroup = row.endsRun
        startsDay = row.separator == .day
        startsTimeGap = row.separator == .pause
        links = row.links.compactMap { link in
            URL(string: link.url).map { MessageItem.Link(range: NSRange(location: Int(link.start), length: Int(link.length)), url: $0) }
        }
        footer = row.footer.map(MessageItem.Footer.init)
        showsDetail = row.shows.detail
        showsWholePost = row.shows.wholePost
    }

    init(_ message: CoreMessage, roomId: String) {
        let state: State = switch message.state {
        case .sending: .sending
        case .sent: .sent
        case .failed: .failed
        }
        let body = switch message.kind {
        case .message: message.body
        case .deleted: "Message deleted"
        case .undecryptable: "Waiting for this message…"
        }
        var photo: Photo?
        var video: Video?
        var file: File?
        switch message.media {
        case .photo(let picture, let isAnimated):
            photo = Photo(ref: .photo(roomId: roomId, messageId: message.id, name: picture.source),
                          width: Int(picture.width), height: Int(picture.height), isAnimated: isAnimated)
        case .video(let poster, let duration):
            photo = poster.map { Photo(ref: .poster(roomId: roomId, messageId: message.id, name: $0.source), width: Int($0.width), height: Int($0.height)) }
            video = Video(duration: Int(duration ?? 0))
        case .file(let name, let size, let mimetype, let kind, let duration):
            let fileKind: File.Kind = switch kind {
            case .document: .document
            case .audio: .audio
            case .voice: .voice
            }
            file = File(name: kind == .voice ? String(localized: "Voice message") : name, size: Int(clamping: size ?? 0),
                        mimetype: mimetype, kind: fileKind, duration: Int(duration ?? 0))
        case nil: break
        }
        self.init(id: message.id, senderId: message.senderId, senderName: message.senderName, body: body, date: message.date,
                  isOwn: message.isOwn, state: state, photo: photo,
                  reactions: message.reactions.map { Reaction(key: $0.key, count: Int($0.count), isMine: $0.isMine) },
                  isEdited: message.isEdited,
                  quote: message.reply.map(PreviewLine.quote),
                  senderAvatar: message.senderAvatar.map { .person(url: $0) })
        self.video = video
        self.file = file
        isEditable = message.isEditable
        eventId = message.eventId ?? ""
        self.roomId = roomId
        isDeleted = message.kind == .deleted
        if case .sending(let upload) = message.state { uploadProgress = upload }
        readers = message.readers.map { Reader(userId: $0.userId, name: $0.name.isEmpty ? $0.userId : $0.name) }
        shared = message.shared.map { MessageItem.SharedPost(url: $0.url, title: $0.title, description: $0.description) }
        if message.kind == .message {
            styles = message.styles.compactMap(TextStyle.init)
        }
    }
}

private extension TextStyle {
    init?(_ style: CoreTextStyle) {
        let kind: Kind
        switch style.kind {
        case .bold: kind = .bold
        case .italic: kind = .italic
        case .underline: kind = .underline
        case .strikethrough: kind = .strikethrough
        case .code: kind = .code
        case .codeBlock: kind = .codeBlock
        case .quote: kind = .quote
        case .link(let url):
            guard let url = URL(string: url) else { return nil }
            kind = .link(url)
        }
        self.init(kind, NSRange(location: Int(style.start), length: Int(style.length)))
    }
}

extension CoreOutgoingAttachment {
    init(_ attachment: OutgoingAttachment) {
        let kind: CoreOutgoingKind = switch attachment.kind {
        case .photo(let width, let height): .photo(width: UInt32(clamping: width), height: UInt32(clamping: height))
        case .video(let width, let height, let duration):
            .video(width: UInt32(clamping: width), height: UInt32(clamping: height), duration: duration)
        case .file: .file
        }
        self.init(file: attachment.file.path, name: attachment.name, mimetype: attachment.mimetype,
                  size: UInt64(clamping: attachment.size), kind: kind,
                  thumbnail: attachment.thumbnail.map {
                      CoreOutgoingThumbnail(file: $0.file.path, mimetype: $0.mimetype, size: UInt64(clamping: $0.size),
                                              width: UInt32(clamping: $0.width), height: UInt32(clamping: $0.height))
                  })
    }
}

extension TextHistoryPage {
    init(_ history: CoreTextHistory) {
        self.init(messages: history.messages.map { message in
            IndexedMessage(eventId: message.eventId, roomId: message.roomId, senderName: message.senderName, body: message.body,
                           date: message.date, isOwn: message.isOwn)
        }, reachedStart: history.reachedStart, removed: history.removed, deletedUntil: history.deletedUntil)
    }
}
