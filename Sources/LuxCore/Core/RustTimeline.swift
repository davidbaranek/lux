import Foundation
import LuxBindings

/// The chats' timelines in the Rust core beside their threads' view models (`RustThread.swift`):
/// opening a chat ahead, the search index's reading, uploads through the rooms' send queues,
/// media loaded into the folder the app gives (the demo's drawn
/// by `DemoMedia`). The generated types stay in `Core/`.
extension RustAccount {
    /// Opens a chat's timeline ahead of time (its first page from the server if the device has
    /// none), so the chat opens at once.
    func prefetch(roomId: String, thread: String? = nil) async { try? await account.prefetchThread(roomId: roomId, threadRoot: thread) }

    /// A chat's text messages and photos, the newest first, back to `since`, the chat's start, or
    /// `maxPages` pages: what the search index reads (`SearchIndexer`).
    func indexHistory(roomId: String, since: Date, maxPages: Int) async throws -> IndexHistoryPage {
        let since = max(since, Date(timeIntervalSince1970: 0))
        return IndexHistoryPage(try await worded {
            try await account.indexHistory(roomId: roomId, since: since, maxPages: UInt32(clamping: maxPages))
        })
    }

    // MARK: Sending

    /// Puts a photo or a file in the chat's send queue (a reply in the Matrix thread of
    /// `threadRoot`, if given); the chat shows it at once, uploading. Returns its message's id
    /// (nil if it did not show in time).
    func send(_ attachment: OutgoingAttachment, roomId: String, threadRoot: String?, caption: String?, replyTo: String?)
        async throws -> String? {
        let attachment = CoreOutgoingAttachment(attachment)
        return try await worded {
            try await account.sendAttachment(roomId: roomId, threadRoot: threadRoot, attachment: attachment, caption: caption,
                                             replyTo: replyTo)
        }
    }

    /// Where a sent photo or file is: uploading, sent, failed.
    func upload(roomId: String, messageId: String) async -> UploadState {
        // gone from the timeline: it went (the chat shows it as sent).
        switch try? await account.sendState(roomId: roomId, messageId: messageId) {
        case .sending(let upload): .uploading(upload ?? 0)
        case .failed: .failed
        case .sent, nil: .sent
        }
    }

    // MARK: Media

    /// The file of an image, downloaded once into `directory`; nil when there is none.
    func imageFile(_ ref: ImageRef, directory: URL) async throws -> URL? {
        if let demo { return try demo.imageFile(ref, directory: directory) }
        let image: CoreImageSource = switch ref {
        case .room(let id, _): .room(roomId: id)
        case .person(let url): .person(url: url)
        case .photo(let roomId, let messageId, _): .photo(roomId: roomId, messageId: messageId)
        case .poster(let roomId, let messageId, _): .poster(roomId: roomId, messageId: messageId)
        case .shared(let roomId, let eventId, _): .shared(roomId: roomId, eventId: eventId)
        }
        return try await worded { try await account.imageFile(image: image, folder: directory.path) }.map { URL(fileURLWithPath: $0) }
    }

    /// A photo's, a video's or a file's original on this device, downloaded once into `directory`.
    func mediaFile(roomId: String, messageId: String, directory: URL) async throws -> URL {
        if let demo { return try demo.mediaFile(roomId: roomId, messageId: messageId, directory: directory) }
        return URL(fileURLWithPath: try await worded { try await account.mediaFile(roomId: roomId, messageId: messageId, folder: directory.path) })
    }

    /// The largest file the server takes, in bytes.
    func maxUploadSize() async throws -> Int { Int(clamping: try await worded { try await account.maxUploadSize() }) }
}
