import Foundation

/// One chat's messages, oldest first, as the core's view model of the thread (`ThreadView`)
/// decides them: it follows the chat's rooms (one, or a merged chat's, shown as one conversation
/// or one room alone), presents the rows, picks where a new message goes (`sendRoom`), and keeps
/// the composer's mode, the read state and who is typing. This model applies its batches on the
/// main actor and forwards the user's intents; the views measure and draw.
@MainActor
public final class ThreadModel {
    /// The chat's id in the list (a merged chat's is no room's).
    public let chatId: String
    /// Every room of the chat: one, or a merged chat's (a Matrix thread's: its one room).
    public let rooms: [ChatRoom]
    /// The Matrix thread shown, its root first; nil: the chat's own timeline.
    public let thread: MatrixThread?
    /// The one room shown alone, or nil: all the rooms together.
    public private(set) var shownRoom: String?
    public var onShownRoom: ((String?) -> Void)?
    /// The merge's own choice, where a chat with no messages yet writes; it also keeps the draft.
    public let defaultRoom: String
    /// The room a new message goes to: the one shown alone, else the room of the conversation's
    /// last message (where the other person last wrote, or the user), else the default.
    public private(set) var sendRoom: String {
        didSet { if sendRoom != oldValue { onSendRoom?(sendNetwork) } }
    }
    /// The network a new message goes through, in a merged chat (where it may change); nil in a
    /// chat of one room.
    public var sendNetwork: String? {
        guard rooms.count > 1 else { return nil }
        return rooms.first { $0.id == sendRoom }?.network
    }
    public var onSendRoom: ((_ network: String?) -> Void)?
    public private(set) var messages: [MessageItem] = []
    /// The core has answered once: an empty `messages` means an empty chat, not "not yet".
    public private(set) var hasLoaded = false
    public private(set) var isAtStart = false
    /// The chat's messages, and why they changed when it is news (the core says so: a message
    /// sent from here, others arriving); the view measures and compares them off the main thread.
    public var onUpdate: ((_ messages: [MessageItem], _ cause: ThreadCause?) -> Void)?
    public var onError: ((Error) -> Void)?
    /// True while messages come from the server: the view shows it, and keeps the chat still.
    public private(set) var isLoading = true {
        didSet { if isLoading != oldValue { onLoading?(isLoading) } }
    }
    public var onLoading: ((Bool) -> Void)?
    /// The rows are the live ones; false while a jump shows an old message among its neighbours.
    public private(set) var isLive = true {
        didSet { if isLive != oldValue { onLive?(isLive) } }
    }
    public var onLive: ((Bool) -> Void)?

    private let account: Task<any ThreadPort, any Error>
    private weak var session: Session?
    /// The settings it reads and keeps: its session's.
    private let preferences: Preferences
    /// The core's thread, once it opened; the intents before wait for it, in order.
    private var core: (any ThreadView)?
    private var waiting: [(any ThreadView) -> Void] = []
    private var opening: Task<(any ThreadView)?, Never>?
    private var following: Task<Void, Never>?
    /// Older messages were asked for and no frame came since: scrolling asks once.
    private var olderAsked = false
    private var olderAllowed = false
    /// The same for newer messages of a jump's rows.
    private var newerAsked = false
    private var newerAllowed = false
    /// The row last told to the core as the one the reader looks at.
    private var anchor: String?
    /// The jumps asked for, by the core's number, until a batch says where each landed: the
    /// batch that holds its rows, so a jump never returns a row the messages lack.
    private var jumps: [UInt64: CheckedContinuation<Result<JumpResult, JumpError>, Never>] = [:]

    /// The chat of `row`, or its Matrix thread `thread`.
    public init(session: Session, row: ChatRow, thread: MatrixThread? = nil) {
        chatId = row.id
        self.thread = thread
        rooms = thread.map { thread in row.chatRooms.filter { $0.id == thread.roomId } } ?? row.chatRooms
        defaultRoom = thread?.roomId ?? row.defaultRoom ?? row.chatRooms[0].id
        sendRoom = defaultRoom
        self.session = session
        preferences = session.preferences
        account = Task { [account = session.account] in try await account.value }
        let receipts = preferences.readReceipts(in: row.id)
        opening = Task { [weak self, account] in
            do {
                let core = try await account.value.openThread(row: row, thread: thread, readReceipts: receipts)
                self?.opened(core)
                return core
            } catch {
                self?.onError?(error)
                return nil
            }
        }
    }

    isolated deinit {
        following?.cancel()
        for jump in jumps.values { jump.resume(returning: .failure(.failed)) }
    }

    private func opened(_ core: any ThreadView) {
        self.core = core
        following = Task { [weak self, events = core.events] in
            for await event in events {
                guard let self else { return }
                handle(event)
            }
        }
        for action in waiting { action(core) }
        waiting = []
    }

    /// Runs `action` on the core's thread now, or once it opened.
    private func withCore(_ action: @escaping (any ThreadView) -> Void) {
        if let core { action(core) } else { waiting.append(action) }
    }

    private func openedCore() async -> (any ThreadView)? {
        if let core { return core }
        return await opening?.value
    }

    // MARK: The core's frames

    private func handle(_ event: ThreadEvent) {
        switch event {
        case .update(let batch): apply(batch)
        case .upload(let files, let roomId, let threadRoot, let caption, let replyTo):
            // what cannot go shows here, in the chat that sent it.
            session?.uploads?.send(files, to: roomId, threadRoot: threadRoot, caption: caption, replyTo: replyTo) { [weak self] error in
                self?.onError?(error)
            }
        case .failed(let failure): onError?(failure)
        }
    }

    private func apply(_ batch: ThreadBatch) {
        let interval = Signposts.thread.beginInterval("messages")
        let unreadBefore = firstUnreadId
        // the state first: the rows are measured with its first unread message.
        if let state = batch.state { apply(state) }
        olderAsked = false
        newerAsked = false
        // a page back is a run of inserts at the top: one splice, not one shift of every row each.
        var run: (start: Int, items: [MessageItem]) = (0, [])
        func flushRun() {
            guard !run.items.isEmpty else { return }
            messages.insert(contentsOf: run.items, at: min(run.start, messages.count))
            run.items = []
        }
        for change in batch.rows {
            if case .insert(let index, let item) = change {
                if !run.items.isEmpty, index == run.start + run.items.count {
                    run.items.append(item)
                    continue
                }
                flushRun()
                run = (index, [item])
                continue
            }
            flushRun()
            switch change {
            case .append(let items): messages.append(contentsOf: items)
            case .clear: messages.removeAll()
            case .pushFront(let item): messages.insert(item, at: 0)
            case .pushBack(let item): messages.append(item)
            case .popFront: if !messages.isEmpty { messages.removeFirst() }
            case .popBack: if !messages.isEmpty { messages.removeLast() }
            case .insert: break
            case .set(let index, let item): if messages.indices.contains(index) { messages[index] = item }
            case .remove(let index): if messages.indices.contains(index) { messages.remove(at: index) }
            case .truncate(let length): if length < messages.count { messages.removeLast(messages.count - length) }
            case .reset(let items): messages = items
            }
        }
        flushRun()
        let first = !hasLoaded
        hasLoaded = true
        Signposts.thread.endInterval("messages", interval, "\(batch.rows.count) changes, \(self.messages.count) messages")
        if first || !batch.rows.isEmpty { onUpdate?(messages, batch.cause) }
        // found after the chat opened (a slow server): the view places the marker now.
        if !first, let found = firstUnreadId, found != unreadBefore { onFirstUnread?(found) }
        // the jumps that landed in these rows, now that the messages hold them.
        for (jump, landed) in batch.jumped { jumps.removeValue(forKey: jump)?.resume(returning: landed) }
    }

    private func apply(_ state: ThreadState) {
        firstUnreadId = state.firstUnread
        isAtStart = state.isAtStart
        olderAllowed = state.canLoadOlder
        newerAllowed = state.canLoadNewer
        isLive = state.isLive
        sendRoom = state.sendRoom
        canSendLater = state.canSendLater
        typists = state.typists
        if state.pinned != pinned || state.mayPinIn != mayPinIn || state.newPin != newPin {
            pinned = state.pinned
            mayPinIn = state.mayPinIn
            newPin = state.newPin
            onPinned?(pinned)
        }
        mode = state.mode
        pendingFiles = state.pendingFiles
        needsReadReceipt = state.needsReadReceipt
        if state.shownRoom != shownRoom {
            shownRoom = state.shownRoom
            onShownRoom?(shownRoom)
        }
        isLoading = state.isLoading
    }

    // MARK: Opening

    /// Shows one room of a merged chat alone (its messages, writing to it), or all of them (nil).
    public func show(room: String?) {
        guard room != shownRoom, room.map({ id in rooms.contains { $0.id == id } }) ?? true else { return }
        withCore { $0.show(room: room) }
    }

    /// Returns once the opening fill is in (what the device has shows as soon as the core has it).
    public func start() async {
        await openedCore()?.loaded()
    }

    // MARK: Details

    /// Shows a message's full time (and its network in a merged chat) under it, or hides them.
    public func toggleDetail(of messageId: String) {
        withCore { $0.toggleDetail(messageId) }
    }

    /// Shows a shared post's whole caption, or folds it to its first lines again.
    public func togglePost(of messageId: String) {
        withCore { $0.togglePost(messageId) }
    }

    /// The row's tap: a row of deleted messages folded together shows each in its own row (for
    /// as long as the chat is open); any other shows or hides its details.
    public func tap(_ message: MessageItem) {
        if message.deletedRun > 0 {
            withCore { $0.unfoldDeleted(message.id) }
        } else {
            toggleDetail(of: message.id)
        }
    }

    /// False while older messages load, and once the chat shows its first message.
    public var canLoadOlder: Bool { !olderAsked && olderAllowed }

    /// Shows older messages (the user scrolled to the top): those the core holds, then the
    /// server's as they come.
    public func loadOlder() {
        guard canLoadOlder else { return }
        olderAsked = true
        withCore { $0.loadOlder() }
    }

    /// Brings the message `messageId` answers into the chat, as `jump(to:)` does.
    public func repliedMessage(of messageId: String) async throws(JumpError) -> JumpResult {
        try await landing { $0.jumpToReplied(messageId) }
    }

    /// Brings a message into the chat: the row to scroll to (among the live rows, or a jump's
    /// rows around it, until the reader returns), or the Matrix thread it is a reply in. The core
    /// answers in the batch that holds the row: `messages` have it when this returns.
    public func jump(to message: MessageLink) async throws(JumpError) -> JumpResult {
        try await landing { $0.jump(to: message) }
    }

    /// Asks the core for a jump, and waits for the batch that says where it landed.
    private func landing(_ jump: (any ThreadView) -> UInt64) async throws(JumpError) -> JumpResult {
        guard let core = await openedCore() else { throw .failed }
        let number = jump(core)
        // registered before any batch can answer it: batches are applied on this actor.
        return try await withCheckedContinuation { jumps[number] = $0 }.get()
    }

    /// False while newer messages of a jump's rows load, and once they reach the newest.
    public var canLoadNewer: Bool { !newerAsked && newerAllowed }

    /// Shows newer messages of a jump's rows (the reader scrolled to their end); at the newest,
    /// the rows go live again.
    public func loadNewer() {
        guard canLoadNewer else { return }
        newerAsked = true
        withCore { $0.loadNewer() }
    }

    /// Shows the live rows again, at the newest ("jump to bottom").
    public func returnToLive() {
        withCore { $0.returnToLive() }
    }

    /// The row the reader looks at among a jump's rows: the switch back to live keeps it in place.
    public func setAnchor(_ messageId: String) {
        guard messageId != anchor else { return }
        anchor = messageId
        withCore { $0.setAnchor(messageId) }
    }

    // MARK: Saved, send later

    public func save(_ message: MessageItem) {
        withCore { $0.save(message.id) }
    }

    public func unsave(_ message: MessageItem) {
        withCore { $0.unsave(message.id) }
    }

    // MARK: Pinned

    /// The messages pinned in the rooms shown, in the order they were pinned (the newest last).
    public private(set) var pinned: [PinnedMessage] = []
    /// The rooms shown where the user may pin and unpin.
    private var mayPinIn: Set<String> = []
    /// The newest pin the user has not seen (on this or another of their devices): the chat tells
    /// of it until they close the note or go to it.
    public private(set) var newPin: PinnedMessage?
    /// The pinned messages changed, who may unpin them, or which is new.
    public var onPinned: (([PinnedMessage]) -> Void)?

    /// Whether the user may unpin `pin` (the room's power levels).
    public func mayUnpin(_ pin: PinnedMessage) -> Bool {
        mayPinIn.contains(pin.roomId)
    }

    /// Unpins `pin` in its room for everyone there.
    public func unpin(_ pin: PinnedMessage) {
        withCore { $0.unpin(roomId: pin.roomId, eventId: pin.eventId) }
    }

    /// The user saw the chat's pins (closed the new pin's note, went to it, or saw the details'
    /// list): none is new until another is pinned.
    public func pinsSeen() {
        guard newPin != nil else { return }
        withCore { $0.pinsSeen() }
    }

    /// Whether `message` is pinned: nil when the user may not pin or unpin it (the room's power
    /// levels, or a message the server does not have yet).
    public func pinning(of message: MessageItem) -> Bool? {
        guard !message.eventId.isEmpty, mayPinIn.contains(message.roomId) else { return nil }
        return pinned.contains { $0.roomId == message.roomId && $0.eventId == message.eventId }
    }

    /// Pins `message` in its room for everyone there, or unpins it.
    public func pin(_ message: MessageItem, _ pinned: Bool) {
        withCore { $0.pin(message.id, pinned) }
    }

    /// The chat can have messages sent later (it is not end-to-end encrypted).
    public private(set) var canSendLater = false

    /// Puts the composer's text on the server to go at `date`, answering what the composer answers.
    public func sendLater(_ text: String, at date: Date) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        preferences.setHasDraft(false, in: chatId)
        Task {
            do {
                try await openedCore()?.sendLater(text, at: date)
                session?.scheduledChanges.send()
            } catch { onError?(error) }
        }
    }

    // MARK: The composer

    /// What sending does: a new message, an answer to one, or a new text for one of yours.
    public enum ComposerMode: Equatable, Sendable {
        case message
        case reply(ReplyPreview)
        case edit(messageId: String, original: String)
    }

    public private(set) var mode = ComposerMode.message {
        didSet { if mode != oldValue { onMode?(mode) } }
    }
    public var onMode: ((ComposerMode) -> Void)?

    public func reply(to message: MessageItem) {
        withCore { $0.reply(to: message.id) }
    }

    public func edit(_ message: MessageItem) {
        guard message.isEditable else { return }
        withCore { $0.edit(message.id) }
    }

    public func cancelMode() {
        withCore { $0.cancelMode() }
    }

    // MARK: Media

    /// A message's photo, video or file on this device, to show full screen or in Quick Look;
    /// an album's every photo, downloaded at once, in its order.
    public func mediaFiles(of message: MessageItem) async throws -> [URL] {
        guard let session else { throw CancellationError() }
        let ids = message.mediaMessageIds, room = message.roomId, directory = session.originalsDirectory
        let account = try await account.value
        return try await withThrowingTaskGroup(of: (Int, URL).self) { group in
            for (index, id) in ids.enumerated() {
                group.addTask { (index, try await account.mediaFile(roomId: room, messageId: id, directory: directory)) }
            }
            var files = [URL?](repeating: nil, count: ids.count)
            for try await (index, file) in group { files[index] = file }
            return files.compactMap { $0 }
        }
    }

    /// Files waiting in the composer to go with the next message (picked, dropped, pasted).
    public private(set) var pendingFiles: [URL] = [] {
        didSet { if pendingFiles != oldValue { onPendingFiles?(pendingFiles) } }
    }
    public var onPendingFiles: (([URL]) -> Void)?

    /// Puts files in the composer; they go with the next message.
    public func attach(_ files: [URL]) {
        withCore { $0.attach(files) }
    }

    public func removePending(_ file: URL) {
        withCore { $0.removePending(file) }
    }

    /// The composer can send: text, or files waiting.
    public func canSend(_ text: String) -> Bool {
        !pendingFiles.isEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Sends the composer's text as the mode says, and returns to a plain message; files waiting
    /// go first, the text as their caption. A new message goes `via` that room, if given (holding
    /// Send), else to `sendRoom`.
    public func send(_ text: String, via room: String? = nil) {
        // sending clears the chat's kept draft (a Matrix thread's is its own).
        if canSend(text), thread == nil { preferences.setHasDraft(false, in: chatId) }
        withCore { $0.send(text, via: room) }
    }

    /// The text and reply the composer had when the chat was left.
    public func loadDraft() async -> String {
        await openedCore()?.loadDraft() ?? ""
    }

    /// Keeps the composer for the next visit (an edit in progress is not a draft).
    public func saveDraft(_ text: String) {
        if case .edit = mode { return }
        var hasReply = false
        if case .reply = mode { hasReply = true }
        // the chat list says "Draft" of the chat's own composer, not a thread's.
        if thread == nil {
            preferences.setHasDraft(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hasReply, in: chatId)
        }
        withCore { $0.saveDraft(text) }
    }

    // MARK: Message actions

    public func delete(_ messageId: String) {
        withCore { $0.delete(messageId) }
    }

    /// Sends a copy of a message to another chat (a merged chat's default room).
    public func forward(_ messageId: String, to chatId: String) {
        withCore { $0.forward(messageId, to: chatId) }
    }

    public func retry(_ messageId: String) {
        withCore { $0.retry(messageId) }
    }

    public func discard(_ messageId: String) {
        withCore { $0.discard(messageId) }
    }

    public func toggleReaction(_ key: String, on messageId: String) {
        withCore { $0.toggleReaction(key, on: messageId) }
    }

    /// The reactions a long press offers first; a sixth button picks any emoji (a menu's palette
    /// shows six).
    public static let quickReactions = ["❤️", "👍", "😂", "😮", "😢"]

    // MARK: Read state

    /// The first unread message when the chat opened: the "New messages" marker goes above it.
    public private(set) var firstUnreadId: String?
    /// The core found the first unread message only after the first messages showed.
    public var onFirstUnread: ((String) -> Void)?

    /// Waits for where the unread messages start; the core finds it as the chat opens, or says
    /// none for now when finding it is slow (the state brings it later).
    public func findFirstUnread() async {
        guard let core = await openedCore(), let found = await core.firstUnread() else { return }
        firstUnreadId = found
    }

    /// Others wrote something the user's read receipt does not cover yet: the composer offers to
    /// send one (the eye button) while it is empty.
    public private(set) var needsReadReceipt = false {
        didSet { if needsReadReceipt != oldValue { onReadState?(needsReadReceipt) } }
    }
    public var onReadState: ((Bool) -> Void)?

    /// How this chat draws its messages, and whether that is its own choice (nil follows the app's).
    public var chatStyle: ChatStyle { preferences.chatStyle(in: chatId) }
    public var chatStyleOverride: ChatStyle? {
        get { preferences.chatStyleOverride(in: chatId) }
        set { preferences.setChatStyle(newValue, in: chatId) }
    }

    /// How this chat sends read receipts, and whether that is its own choice (nil follows the app's).
    public var readReceipts: ReadReceipts { preferences.readReceipts(in: chatId) }
    public var readReceiptsOverride: ReadReceipts? {
        get { preferences.readReceiptsOverride(in: chatId) }
        set {
            preferences.setReadReceipts(newValue, in: chatId)
            let receipts = readReceipts
            withCore { $0.set(readReceipts: receipts) }
        }
    }

    /// The reader is at the newest message: a read receipt goes, if this chat sends them by itself.
    public func didReadLatest() {
        // the views call this as they scroll: only when one is due.
        guard needsReadReceipt, readReceipts == .automatic else { return }
        withCore { $0.didReadLatest() }
    }

    /// Tells the others the chat was read, up to its newest message.
    public func sendReadReceipt() {
        withCore { $0.sendReadReceipt() }
    }

    // MARK: Typing

    /// Who else is typing now.
    public private(set) var typists: [Typist] = [] {
        didSet { if typists != oldValue { onTyping?(typists) } }
    }
    public var onTyping: (([Typist]) -> Void)?

    /// Follows who is typing in the rooms shown, while the chat is shown.
    public func watchTyping() {
        withCore { $0.watchTyping() }
    }

    public func stopWatchingTyping() {
        withCore { $0.stopWatchingTyping() }
    }

    /// The composer's text changed: the others see the user typing (the core decides how often,
    /// and only where the chat tells them it was read by itself).
    public func composerChanged(_ text: String) {
        withCore { $0.composerChanged(text) }
    }
}
