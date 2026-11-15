import Foundation

/// Where a sent photo or file is on its way out.
public enum UploadState: Sendable, Equatable {
    /// Uploading, 0 to 1.
    case uploading(Double)
    case sent
    case failed
}

/// The photos and files being sent, from every chat: each prepared off the main thread, checked
/// against the server's limit, put in its chat's send queue, then followed until it is sent.
/// `progress` counts the bytes of everything in flight, for the platform to show while the app is
/// in the background (on the iPhone, the system's Live Activity of a continued processing task).
@MainActor
public final class Uploads {
    /// The bytes of the files on their way, and how many have gone.
    public let progress = Progress(totalUnitCount: 0)
    /// Files on their way, and how many of them are through.
    public private(set) var files = 0
    public private(set) var finished = 0
    /// Something to send began while nothing was on its way.
    public var onStart: (() -> Void)?
    /// The counts or the bytes changed.
    public var onProgress: (() -> Void)?
    /// Everything is through: true if all went, false if any failed.
    public var onFinish: ((Bool) -> Void)?
    public var onError: ((Error) -> Void)?
    public var isActive: Bool { finished < files }

    private let account: Task<RustAccount, any Error>
    private let directory: URL
    private var failed = false
    /// How much of each file has gone, in bytes, by its message.
    private var sent: [String: Int64] = [:]
    private static let polling: Duration = .milliseconds(400)

    init(account: Task<RustAccount, any Error>, directory: URL) {
        self.account = account
        self.directory = directory
    }

    /// Sends files to a chat (as replies in the Matrix thread of `threadRoot`, if given), one
    /// message each, in order; a reply answers with the first, and `caption` goes with the first
    /// as its text.
    public func send(_ urls: [URL], to roomId: String, threadRoot: String? = nil, caption: String? = nil, replyTo: String?) {
        guard !urls.isEmpty else { return }
        if !isActive {
            files = 0
            finished = 0
            failed = false
            sent = [:]
            progress.totalUnitCount = 0
            progress.completedUnitCount = 0
        }
        files += urls.count
        onProgress?()
        if files == urls.count { onStart?() }
        Task { [account, directory] in
            let limit = try? await account.value.maxUploadSize()
            var replyTo = replyTo
            var caption = caption
            for url in urls {
                do {
                    let attachment = try await AttachmentMaker.prepare(url, in: directory)
                    if let limit, attachment.size > limit { throw AttachmentMaker.Failure.tooLarge(name: attachment.name, limit: limit) }
                    let size = Int64(attachment.size)
                    progress.totalUnitCount += size
                    let id = try await account.value.send(attachment, roomId: roomId, threadRoot: threadRoot, caption: caption,
                                                          replyTo: replyTo)
                    replyTo = nil
                    caption = nil
                    if let id { follow(id, in: roomId, size: size) } else { done(id: nil, size: size, ok: true) }
                } catch {
                    onError?(error)
                    done(id: nil, size: 0, ok: false)
                }
            }
        }
    }

    /// Follows one file's upload until it is sent or fails.
    private func follow(_ messageId: String, in roomId: String, size: Int64) {
        Task { [account] in
            guard let account = try? await account.value else { return done(id: messageId, size: size, ok: false) }
            while true {
                switch await account.upload(roomId: roomId, messageId: messageId) {
                case .uploading(let fraction):
                    moved(messageId, to: Int64(Double(size) * fraction))
                case .sent:
                    return done(id: messageId, size: size, ok: true)
                case .failed:
                    return done(id: messageId, size: size, ok: false)
                }
                try? await Task.sleep(for: Self.polling)
            }
        }
    }

    private func moved(_ messageId: String, to bytes: Int64) {
        progress.completedUnitCount += bytes - (sent[messageId] ?? 0)
        sent[messageId] = bytes
        onProgress?()
    }

    private func done(id: String?, size: Int64, ok: Bool) {
        if let id { moved(id, to: size) } else { progress.completedUnitCount += size }
        if !ok { failed = true }
        finished += 1
        onProgress?()
        if !isActive { onFinish?(!failed) }
    }
}
