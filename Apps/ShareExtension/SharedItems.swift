import UIKit
import UniformTypeIdentifiers

/// What another app shares, read from its item providers: files (photos, videos, documents)
/// copied where the extension can send them from, and the text and links as one line.
struct SharedItems {
    var files: [URL] = []
    var text = ""

    /// Reads `providers` into `folder`: each its file if it has one, else its link or text.
    @MainActor
    static func read(_ providers: [NSItemProvider], into folder: URL) async -> SharedItems {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var items = SharedItems()
        var lines: [String] = []
        for provider in providers {
            if let type = [UTType.image, .movie, .fileURL, .data].first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }),
               type != .data || !provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
               let file = await copy(provider, type: type, into: folder) {
                items.files.append(file)
            } else if case .url(let url) = await load(provider, type: .url) {
                lines.append(url.absoluteString)
            } else if case .text(let text) = await load(provider, type: .plainText) {
                lines.append(text)
            }
        }
        items.text = lines.joined(separator: "\n")
        return items
    }

    /// The provider's file of `type`, copied into `folder` under its own name.
    @MainActor
    private static func copy(_ provider: NSItemProvider, type: UTType, into folder: URL) async -> URL? {
        let suggested = provider.suggestedName
        return await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, _ in
                // the file goes away when this returns: copied now.
                guard let url else { return continuation.resume(returning: nil) }
                let name = suggested.map { name in
                    url.pathExtension.isEmpty || name.hasSuffix(url.pathExtension) ? name : name + "." + url.pathExtension
                } ?? url.lastPathComponent
                let place = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
                let file = place.appendingPathComponent(name)
                do {
                    try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: url, to: file)
                    continuation.resume(returning: file)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// The provider's item of `type` (a link's URL, a text's string).
    @MainActor
    private static func load(_ provider: NSItemProvider, type: UTType) async -> Loaded? {
        guard provider.hasItemConformingToTypeIdentifier(type.identifier) else { return nil }
        return await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type.identifier) { item, _ in
                continuation.resume(returning: (item as? URL).map(Loaded.url) ?? (item as? String).map(Loaded.text))
            }
        }
    }

    /// A link or a text, as a provider gives it.
    private enum Loaded: Sendable {
        case url(URL)
        case text(String)
    }
}

/// The shared photos and files above the message: small tiles in a row, a photo's picture or a
/// file's symbol and name.
final class SharePreviewView: UIStackView {
    init() {
        super.init(frame: .zero)
        axis = .horizontal
        spacing = 8
        alignment = .center
        isHidden = true
    }

    @available(*, unavailable) required init(coder: NSCoder) { fatalError() }

    func show(_ items: SharedItems) {
        arrangedSubviews.forEach { $0.removeFromSuperview() }
        isHidden = items.files.isEmpty
        for file in items.files.prefix(4) { addArrangedSubview(Self.tile(file)) }
        if items.files.count > 4 {
            let more = UILabel()
            more.text = "+\(items.files.count - 4)"
            more.font = .preferredFont(forTextStyle: .headline)
            more.textColor = .secondaryLabel
            addArrangedSubview(more)
        }
        addArrangedSubview(UIView())
    }

    private static func tile(_ file: URL) -> UIView {
        let side: CGFloat = 64
        let tile = UIImageView()
        tile.contentMode = .scaleAspectFill
        tile.clipsToBounds = true
        tile.layer.cornerRadius = 10
        tile.layer.cornerCurve = .continuous
        tile.backgroundColor = .tertiarySystemFill
        tile.tintColor = .secondaryLabel
        tile.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([tile.widthAnchor.constraint(equalToConstant: side), tile.heightAnchor.constraint(equalToConstant: side)])
        let type = UTType(filenameExtension: file.pathExtension) ?? .data
        if type.conforms(to: .image), let image = UIImage(contentsOfFile: file.path)?.preparingThumbnail(of: CGSize(width: side * 3, height: side * 3)) {
            tile.image = image
        } else {
            tile.contentMode = .center
            tile.image = UIImage(systemName: type.conforms(to: .movie) ? "film" : "doc",
                                 withConfiguration: UIImage.SymbolConfiguration(pointSize: 24))
        }
        tile.accessibilityLabel = file.lastPathComponent
        tile.isAccessibilityElement = true
        return tile
    }
}
