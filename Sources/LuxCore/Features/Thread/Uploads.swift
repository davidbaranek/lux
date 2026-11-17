import Foundation

/// Where a sent photo or file is on its way out.
public enum UploadState: Sendable, Equatable {
    /// Uploading, 0 to 1.
    case uploading(Double)
    case sent
    case failed
}

/// The account's photos and files being sent, from every chat: each prepared off the main
/// thread, checked against the server's limit, put in its chat's send queue, then followed as the
/// core streams its upload until it is sent. `progress` counts the bytes of everything in flight,
/// for the platform to show while the app is in the background (on the iPhone, the system's Live
/// Activity of a continued processing task). It ends with its account (`close`).
@MainActor
public final class Uploads {
    /// The bytes of the files on their way, and how many have gone: a new one each time sending
    /// starts while nothing is on its way, so the platform can make it a child of its own.
    public private(set) var progress = Progress(totalUnitCount: 0)
    /// Files on their way, and how many of them are through.
    public private(set) var files = 0
    public private(set) var finished = 0
    /// Something to send began while nothing was on its way.
    public var onStart: (() -> Void)?
    /// The counts or the bytes changed.
    public var onProgress: (() -> Void)?
    /// Everything is through: true if all went, false if any failed.
    public var onFinish: ((Bool) -> Void)?
    public var isActive: Bool { finished < files }

    private let account: Task<any UploadsPort, any Error>
    private let directory: URL
    private var failed = false
    private let tasks = TaskBag()

    init(account: Task<any UploadsPort, any Error>, directory: URL) {
        self.account = account
        self.directory = directory
    }

    /// Sends files to a chat (as replies in the Matrix thread of `threadRoot`, if given), one
    /// message each, in order; a reply answers with the first, and `caption` goes with the first
    /// as its text. A file that cannot go (unreadable, over the server's limit, refused by the
    /// queue) goes to `failure`, in the user's words: the chat that sent it shows it.
    public func send(_ urls: [URL], to roomId: String, threadRoot: String? = nil, caption: String? = nil, replyTo: String?,
                     failure: @escaping @MainActor (any Error) -> Void) {
        guard !urls.isEmpty else { return }
        if !isActive {
            files = 0
            finished = 0
            failed = false
            progress = Progress(totalUnitCount: 0)
        }
        files += urls.count
        onProgress?()
        if files == urls.count { onStart?() }
        tasks.run { [weak self, account, directory] in
            // unknown, the server refuses what is too large itself.
            let limit = await bestEffort("the server's upload limit") { try await account.value.maxUploadSize() } ?? nil
            var replyTo = replyTo
            var caption = caption
            for url in urls {
                do {
                    let attachment = try await AttachmentMaker.prepare(url, in: directory)
                    if let limit, attachment.size > limit { throw AttachmentMaker.Failure.tooLarge(name: attachment.name, limit: limit) }
                    let size = Int64(attachment.size)
                    self?.progress.totalUnitCount += size
                    let states = try await account.value.send(attachment, roomId: roomId, threadRoot: threadRoot, caption: caption,
                                                              replyTo: replyTo)
                    replyTo = nil
                    caption = nil
                    self?.follow(states, size: size)
                } catch {
                    // closed with its account: nothing is counted any more.
                    guard !Task.isCancelled, let self else { return }
                    failure(error)
                    done(ok: false)
                }
            }
        }
    }

    /// The account closed: its uploads are no longer followed, and what was on its way ends, not
    /// all through (the files stay in their chats' queues on the server's side of the account).
    func close() {
        tasks.cancelAll()
        guard isActive else { return }
        failed = true
        finished = files
        onProgress?()
        onFinish?(false)
    }

    /// Follows one file's upload, `size` bytes, as the core streams it, until it is sent, fails or
    /// is discarded.
    private func follow(_ states: AsyncStream<UploadState>, size: Int64) {
        tasks.run { [weak self] in
            var gone: Int64 = 0
            var ok = true
            for await state in states {
                switch state {
                case .uploading(let share):
                    let bytes = Int64(Double(size) * share)
                    self?.moved(bytes - gone)
                    gone = bytes
                case .sent: break
                case .failed: ok = false
                }
            }
            guard !Task.isCancelled, let self else { return }
            // through, whichever way: the bar ends full.
            moved(size - gone)
            done(ok: ok)
        }
    }

    private func moved(_ bytes: Int64) {
        progress.completedUnitCount += bytes
        onProgress?()
    }

    private func done(ok: Bool) {
        if !ok { failed = true }
        finished += 1
        onProgress?()
        if !isActive { onFinish?(!failed) }
    }
}
