import AVFoundation
import Foundation

/// How a video goes: made smaller for sending (H.264 at 1080p, as Signal and Telegram send it by
/// default), or the file as it is.
public enum VideoQuality: Sendable, Equatable {
    case optimized
    case original
}

/// What a video waiting in the composer is: how it will go, whether it may go as it is, and how
/// far its smaller copy is made.
public struct PendingVideo: Sendable, Equatable {
    public var quality: VideoQuality
    /// Within the server's limit as it is: Original may be chosen.
    public var canSendOriginal: Bool
    /// Making the smaller copy, 0 to 1; nil once made, or going as it is.
    public var progress: Double?
}

/// Makes a video smaller to send, with AVFoundation's export (no encoder of our own), off the main
/// thread.
public enum VideoExport {
    public enum Failure: LocalizedError {
        case unreadable(String)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let name): String(localized: "\(name) could not be made smaller.")
            }
        }
    }

    /// The export preset a video of this upright size and length in bytes goes through, or nil to
    /// send it as it is: optimized, one larger than 1080p becomes 1080p, and one over the server's
    /// `limit` becomes 720p; the original goes as it is (Uploads holds it to the limit).
    public static func preset(width: Int, height: Int, bytes: Int, limit: Int?, quality: VideoQuality) -> String? {
        guard quality == .optimized else { return nil }
        if max(width, height) > 1920 || min(width, height) > 1080 { return AVAssetExportPreset1920x1080 }
        if let limit, bytes > limit { return AVAssetExportPreset1280x720 }
        return nil
    }

    /// Whether the video may go as it is: within the server's limit, or the limit is unknown (the
    /// server refuses what is too large itself).
    public static func canSendOriginal(bytes: Int, limit: Int?) -> Bool {
        limit.map { bytes <= $0 } ?? true
    }

    /// The video's upright size and its length in bytes.
    @concurrent
    public static func measure(_ file: URL) async throws -> (width: Int, height: Int, bytes: Int) {
        let tracks = try await AVURLAsset(url: file).load(.tracks)
        guard let track = tracks.first(where: { $0.mediaType == .video }) else { throw Failure.unreadable(file.lastPathComponent) }
        let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
        let upright = natural.applying(transform)
        let bytes = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        return (Int(abs(upright.width)), Int(abs(upright.height)), bytes)
    }

    /// Writes `source` through `preset` as an MP4 for streaming, in a folder of its own in
    /// `directory`, under the source's name; `progress` hears how far it is, 0 to 1. Cancelling
    /// the task stops the export.
    @concurrent
    public static func export(_ source: URL, preset: String, in directory: URL,
                              progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let name = source.lastPathComponent
        guard let session = AVAssetExportSession(asset: AVURLAsset(url: source), presetName: preset) else {
            throw Failure.unreadable(name)
        }
        session.shouldOptimizeForNetworkUse = true
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(source.deletingPathExtension().lastPathComponent).appendingPathExtension("mp4")
        let states = session.states(updateInterval: 0.2)
        try await withThrowingDiscardingTaskGroup { group in
            group.addTask {
                for await state in states {
                    if case .exporting(let made) = state { progress(made.fractionCompleted) }
                }
            }
            try await session.export(to: file, as: .mp4)
            group.cancelAll()
        }
        progress(1)
        return file
    }
}
