import Foundation

/// Sending photos and files and following their uploads. What `Uploads` needs of an account; the
/// Rust core's account adapts it (`RustTimeline.swift`).
protocol UploadsPort: Sendable {
    /// The largest file the server takes, in bytes.
    func maxUploadSize() async throws -> Int
    /// Puts `attachment` in the chat's send queue (a reply in the Matrix thread of `threadRoot`,
    /// if given). Its upload's states: how much has gone, each time more has, then sent or failed,
    /// the last; the stream ends there, or when the message is discarded before it went.
    func send(_ attachment: OutgoingAttachment, roomId: String, threadRoot: String?, caption: ComposedText?, replyTo: String?)
        async throws -> AsyncStream<UploadState>
}
