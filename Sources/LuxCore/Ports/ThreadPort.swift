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
    func jumpToReplied(_ messageId: String) async -> String?
    func jumpToEvent(_ eventId: String) async -> String?
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
}
