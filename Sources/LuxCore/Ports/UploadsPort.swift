import Foundation

/// Sending photos and files and following their uploads. What `Uploads` needs of an account; the
/// Rust core's account adapts it (`RustTimeline.swift`).
protocol UploadsPort: Sendable {
    /// The largest file the server takes, in bytes.
    func maxUploadSize() async throws -> Int
    /// Puts `attachment` in the chat's send queue (a reply in the Matrix thread of `threadRoot`,
    /// if given); its message's id, nil if it did not show in time.
    func send(_ attachment: OutgoingAttachment, roomId: String, threadRoot: String?, caption: String?, replyTo: String?)
        async throws -> String?
    /// Where a sent photo or file is: uploading, sent, failed.
    func upload(roomId: String, messageId: String) async throws -> UploadState
}
