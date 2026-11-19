import Foundation

/// Opening a chat's thread and fetching its media. What `ThreadModel` needs of an account; the
/// Rust core's account adapts it (`RustThread.swift`, `RustTimeline.swift`).
protocol ThreadPort: Sendable {
    /// A chat's thread (the Matrix thread `thread` in it, if given), following its rooms'
    /// timelines while it lives.
    func openThread(row: ChatRow, thread: MatrixThread?, readReceipts: ReadReceipts) -> any ThreadView
    /// Downloads a message's media into `directory`; the file.
    func mediaFile(roomId: String, messageId: String, directory: URL) async throws -> URL
}

/// A chat's thread as the core presents it: its rows and state as they change, and what the
/// user does in it.
protocol ThreadView: Sendable {
    /// The thread's events as they come, one per frame at most.
    var events: AsyncStream<ThreadEvent> { get }
    func loadOlder()
    /// Brings the message `messageId` quotes into the thread.
    func jumpToReplied(_ messageId: String) async throws(JumpError) -> JumpResult
    /// Brings a message into the thread: among the live rows, or a jump's rows around it.
    func jump(to message: MessageLink) async throws(JumpError) -> JumpResult
    /// Newer messages of a jump's rows.
    func loadNewer()
    /// The live rows again, at the newest.
    func returnToLive()
    /// The row the reader looks at: the switch back to the live rows keeps it in place.
    func setAnchor(_ messageId: String)
    func firstUnread() async -> String?
    func loaded() async
    func toggleDetail(_ messageId: String)
    func togglePost(_ messageId: String)
    func show(room: String?)
    func reply(to messageId: String)
    func edit(_ messageId: String)
    func cancelMode()
    func send(_ text: String, via room: String?)
    func sendLater(_ text: String, at date: Date) async throws
    func attach(_ files: [URL])
    func removePending(_ file: URL)
    func toggleReaction(_ key: String, on messageId: String)
    func delete(_ messageId: String)
    func retry(_ messageId: String)
    func discard(_ messageId: String)
    func forward(_ messageId: String, to chatId: String)
    func save(_ messageId: String)
    func unsave(_ messageId: String)
    /// Pins a message in its room for everyone there, or unpins it.
    func pin(_ messageId: String, _ pinned: Bool)
    /// Unpins a pinned message by its event, whether or not its row is loaded.
    func unpin(roomId: String, eventId: String)
    /// The user saw the chat's pins: none is new until another is pinned.
    func pinsSeen()
    func didReadLatest()
    func sendReadReceipt()
    func set(readReceipts: ReadReceipts)
    func watchTyping()
    func stopWatchingTyping()
    func composerChanged(_ text: String)
    func loadDraft() async -> String
    func saveDraft(_ text: String)
}

enum ThreadEvent: Sendable {
    case update(ThreadBatch)
    /// Files the user sent: the platform prepares and uploads them (to the Matrix thread
    /// of `threadRoot`, if any).
    case upload(files: [URL], roomId: String, threadRoot: String?, caption: String?, replyTo: String?)
    case failed(AccountFailure)
}

/// One frame: the rows' changes, and the state when it changed.
struct ThreadBatch: Sendable {
    var rows: [ThreadRowChange]
    var state: ThreadState?
    /// The rows switched between a jump's and the live ones: `to` goes where `from` was.
    var anchor: (from: String, to: String)?
}

/// A change to the rows, as the core's `VectorDiff`.
enum ThreadRowChange: Sendable {
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

struct ThreadState: Sendable, Equatable {
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
    /// The rows are the live ones, not a jump's.
    var isLive: Bool
    var canLoadNewer: Bool
    /// The messages pinned in the rooms shown, in the order they were pinned.
    var pinned: [PinnedMessage]
    /// The rooms shown where the user may pin and unpin.
    var mayPinIn: Set<String>
    /// The newest pin the user has not seen: the chat tells of it until they close it or go to it.
    var newPin: PinnedMessage?
}
