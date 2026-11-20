import Foundation
import UniformTypeIdentifiers

/// The videos waiting in the composer that would go smaller (`VideoExport`): each is made smaller
/// as soon as it waits, so it is usually ready by the time the user sends, unless the user
/// chooses Original. A video over the server's limit can only go smaller. The video in the
/// composer stays the original; at sending, its smaller copy goes in its place (`take`), awaited
/// by the upload if it is not ready yet.
@MainActor
public final class PendingVideos {
    /// The videos with a choice, by their file in the composer.
    public private(set) var videos: [URL: PendingVideo] = [:] {
        didSet { if videos != oldValue { onChange?() } }
    }
    public var onChange: (() -> Void)?
    private var exports: [URL: Task<URL, any Error>] = [:]
    private var measured: [URL: (width: Int, height: Int, bytes: Int, limit: Int?)] = [:]
    private var measuring: Set<URL> = []
    private let directory: URL
    private let limit: @MainActor () async -> Int?
    private let tasks = TaskBag()

    /// Smaller copies go to `directory`; `limit` is the server's, nil if unknown.
    init(directory: URL, limit: @escaping @MainActor () async -> Int?) {
        self.directory = directory
        self.limit = limit
    }

    isolated deinit {
        for export in exports.values { export.cancel() }
    }

    /// The composer's files changed: each new video is measured, and made smaller if it would go so.
    func follow(_ files: [URL]) {
        for file in files where videos[file] == nil && !measuring.contains(file) && Self.isVideo(file) {
            measuring.insert(file)
            tasks.run { [weak self] in
                let size = await bestEffort("pending video: measure") { try await VideoExport.measure(file) }
                let limit = await self?.limit()
                guard let self else { return }
                measuring.remove(file)
                guard let size else { return }
                measured[file] = (size.width, size.height, size.bytes, limit)
                // one that goes as it is anyway has no choice.
                guard VideoExport.preset(width: size.width, height: size.height, bytes: size.bytes, limit: limit, quality: .optimized) != nil
                else { return }
                videos[file] = PendingVideo(quality: .optimized,
                                            canSendOriginal: VideoExport.canSendOriginal(bytes: size.bytes, limit: limit), progress: nil)
                makeSmaller(file)
            }
        }
    }

    /// Optimized makes the smaller copy (again); Original stops it and the video goes as it is,
    /// if the server takes it so.
    public func setQuality(_ quality: VideoQuality, of file: URL) {
        guard var video = videos[file], video.quality != quality else { return }
        if quality == .original, !video.canSendOriginal { return }
        video.quality = quality
        videos[file] = video
        switch quality {
        case .optimized: makeSmaller(file)
        case .original: stop(file)
        }
    }

    /// A file that came only as it was sent: a video is made smaller then, if it would go so.
    func readyToSend(_ file: URL) async throws -> URL {
        guard Self.isVideo(file) else { return file }
        let size = try await VideoExport.measure(file)
        let limit = await limit()
        guard let preset = VideoExport.preset(width: size.width, height: size.height, bytes: size.bytes, limit: limit, quality: .optimized)
        else { return file }
        return try await VideoExport.export(file, preset: preset, in: directory) { _ in }
    }

    /// The video was taken out of the composer: its copy is no longer made.
    func remove(_ file: URL) {
        stop(file)
        videos[file] = nil
        measured[file] = nil
    }

    /// The files are sent: the smaller copies of those going so, ready or on their way, are the
    /// upload's from now on.
    func take(_ files: [URL]) -> [URL: Task<URL, any Error>] {
        var taken: [URL: Task<URL, any Error>] = [:]
        for file in files {
            if videos[file]?.quality == .optimized { taken[file] = exports[file] }
            exports[file] = nil
            videos[file] = nil
            measured[file] = nil
        }
        return taken
    }

    private func makeSmaller(_ file: URL) {
        guard let size = measured[file],
              let preset = VideoExport.preset(width: size.width, height: size.height, bytes: size.bytes, limit: size.limit, quality: .optimized)
        else { return }
        exports[file]?.cancel()
        videos[file]?.progress = 0
        let directory = directory
        let export = Task { [weak self] in
            try await VideoExport.export(file, preset: preset, in: directory) { made in
                Task { @MainActor in self?.made(made, of: file) }
            }
        }
        exports[file] = export
        tasks.run { [weak self] in
            let copy = await bestEffort("pending video: make smaller") { try await export.value }
            guard let self, exports[file] == export else { return }
            videos[file]?.progress = nil
            // a copy that could not be made: the original goes (the log says why).
            if copy == nil { exports[file] = nil }
        }
    }

    private func made(_ share: Double, of file: URL) {
        guard videos[file]?.progress != nil else { return }
        videos[file]?.progress = min(share, 1)
    }

    private func stop(_ file: URL) {
        exports.removeValue(forKey: file)?.cancel()
        videos[file]?.progress = nil
    }

    private static func isVideo(_ file: URL) -> Bool {
        UTType(filenameExtension: file.pathExtension)?.conforms(to: .movie) ?? false
    }
}
