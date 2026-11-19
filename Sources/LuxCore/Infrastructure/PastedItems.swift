import Foundation
import UniformTypeIdentifiers

/// What a paste or a drop brings the composer that is not text: a file, a picture, a video. Each
/// becomes a file of its own, which waits in the composer as one picked with the + does
/// (`ThreadModel.attach`), and goes the same way from there: `AttachmentMaker` makes it ready,
/// `Uploads` holds it to the server's limit.
public enum PastedItems {
    /// One item of a pasteboard the composer attaches: a file where it is, or bytes to write out.
    public enum Item: Sendable, Equatable {
        case file(URL)
        /// A picture or a file that is only on the pasteboard (a screenshot, a copied image), its
        /// name if the pasteboard has one.
        case data(Data, type: UTType, name: String?)
    }

    /// The type an item offering `identifiers` attaches as (they come richest first), or nil for
    /// text, which the text view pastes itself. A file's URL is the file (Finder offers its name
    /// as text beside it); else an item with text is text (rich text with a picture in it, a
    /// link); else its first picture or video, TIFF last (the Mac offers one beside the PNG or
    /// JPEG it was made from); else its first other data.
    public static func attachableType(of identifiers: [String]) -> UTType? {
        let types = identifiers.compactMap { UTType($0) }.filter { $0.isDeclared && !$0.isDynamic }
        if types.contains(.fileURL) { return .fileURL }
        if types.contains(where: isText) { return nil }
        let data = types.filter { $0.conforms(to: .data) && !$0.conforms(to: .url) }
        let media = data.filter { $0.conforms(to: .image) || $0.conforms(to: .movie) }
        return media.first { !$0.conforms(to: .tiff) } ?? media.first ?? data.first
    }

    private static func isText(_ type: UTType) -> Bool {
        type.conforms(to: .text) || type.conforms(to: .rtfd) || type.conforms(to: .flatRTFD)
    }

    /// The files `items` stand for, in their order: a file as it is, bytes written to a file of
    /// their own in `directory`, named as the pasteboard names them or for what they are
    /// ("Pasted Image.png"). Off the main thread: a screenshot is megabytes.
    @concurrent
    public static func files(_ items: [Item], in directory: URL) async throws -> [URL] {
        try items.map { item in
            switch item {
            case .file(let url): return url
            case .data(let data, let type, let name):
                let file = try newFile(named: fileName(name, type: type), in: directory)
                try data.write(to: file)
                return file
            }
        }
    }

    /// The file an item provider holds (a pasted or dropped photo, video or file), copied into a
    /// folder of its own in `directory` before the provider lets it go, named `name` if given,
    /// else as the provider's file is (a file by its URL keeps its own name). It stays on the
    /// caller's actor (a provider is not `Sendable`); the provider copies on a queue of its own.
    public nonisolated(nonsending) static func file(from provider: NSItemProvider, type: UTType, name: String? = nil,
                                                    in directory: URL) async throws -> URL {
        if type == .fileURL {
            return try await withCheckedThrowingContinuation { continuation in
                _ = provider.loadObject(ofClass: URL.self) { url, error in
                    guard let url else { return continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
                    continuation.resume(with: Result { try copy(url, named: url.lastPathComponent, into: directory) })
                }
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, error in
                guard let url else { return continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
                let named = name.map { fileName($0, type: type) } ?? url.lastPathComponent
                continuation.resume(with: Result { try copy(url, named: named, into: directory) })
            }
        }
    }

    /// `name` with the extension of `type` (a pasteboard's name often has none), or a name for
    /// what it is.
    public static func fileName(_ name: String?, type: UTType) -> String {
        let base = name.flatMap { $0.isEmpty ? nil : $0 } ?? defaultName(for: type)
        let named = (base as NSString).pathExtension
        if !named.isEmpty, let own = UTType(filenameExtension: named), own.conforms(to: type) { return base }
        guard let suffix = type.preferredFilenameExtension else { return base }
        return "\(base).\(suffix)"
    }

    private static func defaultName(for type: UTType) -> String {
        if type.conforms(to: .image) { return String(localized: "Pasted Image") }
        if type.conforms(to: .movie) { return String(localized: "Pasted Video") }
        return String(localized: "Pasted File")
    }

    private static func newFile(named name: String, in directory: URL) throws -> URL {
        // a folder each: two pastes of "Pasted Image.png" keep their names.
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(name)
    }

    private static func copy(_ url: URL, named name: String, into directory: URL) throws -> URL {
        let file = try newFile(named: name, in: directory)
        try FileManager.default.copyItem(at: url, to: file)
        return file
    }
}
