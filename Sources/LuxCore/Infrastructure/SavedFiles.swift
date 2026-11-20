import Foundation
import UniformTypeIdentifiers

/// Copies of a chat's photos, videos and files kept outside it, where the user says. The originals
/// come from the session's own folder (`ThreadModel.mediaFiles`, where the core decrypts each
/// once); a copy goes nowhere else than the user's destination. It is written beside its
/// destination under a hidden name and moved into place only once whole, so a copy that fails
/// leaves nothing behind, and one that is under way is never seen half written. The copying is
/// the file system's (a clone where it can, else streamed), off the main thread.
public enum SavedFiles {
    /// Copies `files` into `folder` under their own names, each under a name not taken there yet
    /// ("Trip plan.pdf", then "Trip plan 2.pdf"), as Safari saves into Downloads. The copies, in order.
    @concurrent
    public static func save(_ files: [URL], into folder: URL) async throws -> [URL] {
        try files.map { file in
            let partial = try partialCopy(of: file, in: folder)
            defer { remove(partial) }
            for candidate in names(for: file.lastPathComponent) {
                let destination = folder.appendingPathComponent(candidate)
                do {
                    // a move does not replace: a name taken meanwhile tries the next.
                    try FileManager.default.moveItem(at: partial, to: destination)
                    return destination
                } catch CocoaError.fileWriteFileExists {
                    continue
                }
            }
            throw CocoaError(.fileWriteFileExists)
        }
    }

    /// Copies `file` to `destination`, replacing what is there (the save panel asked the user), or
    /// to where a drag promised it.
    @concurrent
    public static func save(_ file: URL, as destination: URL) async throws {
        let partial = try partialCopy(of: file, in: destination.deletingLastPathComponent())
        defer { remove(partial) }
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: partial)
        } else {
            try FileManager.default.moveItem(at: partial, to: destination)
        }
    }

    /// The name a file of `message` will have before it is downloaded (a drag out of the chat
    /// promises one): a file's own name, else what the sender called the photo or video, else
    /// "Photo.jpg" or "Video.mp4".
    public static func promisedName(for message: MessageItem) -> String {
        if let file = message.file, !file.name.isEmpty { return file.name }
        let isVideo = message.video != nil
        let type: UTType = isVideo ? .mpeg4Movie : .jpeg
        let fallback = isVideo ? String(localized: "Video") : String(localized: "Photo")
        let body = message.body.trimmingCharacters(in: .whitespacesAndNewlines)
        // a caption is no name; a sender's "IMG_0042.HEIC" is.
        let suffix = (body as NSString).pathExtension
        guard !body.contains("\n"), !suffix.isEmpty, let named = UTType(filenameExtension: suffix) else {
            return PastedItems.fileName(fallback, type: type)
        }
        return PastedItems.fileName(body, type: named)
    }

    /// The bytes of a picture, for the pasteboard beside its file (an app that takes pictures, not
    /// files, pastes these); nil for anything else. Off the main thread: a photo is megabytes.
    @concurrent
    public static func image(in file: URL) async throws -> (type: UTType, data: Data)? {
        guard let type = UTType(filenameExtension: file.pathExtension), type.conforms(to: .image) else { return nil }
        return (type, try Data(contentsOf: file, options: .mappedIfSafe))
    }

    /// "Trip plan.pdf", "Trip plan 2.pdf", "Trip plan 3.pdf", …
    static func names(for name: String) -> [String] {
        let base = (name as NSString).deletingPathExtension, suffix = (name as NSString).pathExtension
        return [name] + (2...999).map { suffix.isEmpty ? "\(base) \($0)" : "\(base) \($0).\(suffix)" }
    }

    /// A whole copy of `file` in `folder` under a hidden name of its own.
    private static func partialCopy(of file: URL, in folder: URL) throws -> URL {
        let partial = folder.appendingPathComponent(".\(UUID().uuidString).\(file.pathExtension)")
        do {
            try FileManager.default.copyItem(at: file, to: partial)
        } catch {
            remove(partial)
            throw error
        }
        return partial
    }

    /// The partial copy goes, if it is still there (it is not once moved into place).
    private static func remove(_ partial: URL) {
        guard FileManager.default.fileExists(atPath: partial.path) else { return }
        _ = bestEffort("saved file: the partial copy") { try FileManager.default.removeItem(at: partial) }
    }
}
