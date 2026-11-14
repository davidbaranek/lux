import AppKit
import QuickLookThumbnailing

/// The files waiting in the composer, in a row above the text: each as Quick Look draws it, with
/// a button that takes it out.
final class AttachmentStrip: NSView {
    static let side: CGFloat = 56
    var onRemove: ((URL) -> Void)?
    private let row = NSStackView()
    private var tiles: [URL: AttachmentTile] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        row.orientation = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            row.heightAnchor.constraint(equalToConstant: Self.side),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(_ files: [URL]) {
        var kept: [URL: AttachmentTile] = [:]
        for file in files {
            kept[file] = tiles[file] ?? AttachmentTile(file: file) { [weak self] in self?.onRemove?(file) }
        }
        tiles = kept
        row.setViews(files.compactMap { kept[$0] }, in: .leading)
    }
}

private final class AttachmentTile: NSView {
    private let picture = NSImageView()
    private let remove = NSButton()
    private let action: () -> Void

    init(file: URL, remove action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true
        picture.imageScaling = .scaleProportionallyUpOrDown
        picture.wantsLayer = true
        picture.layer?.cornerRadius = 10
        picture.layer?.masksToBounds = true
        picture.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        picture.toolTip = file.lastPathComponent
        remove.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: String(localized: "Remove \(file.lastPathComponent)"))
        remove.symbolConfiguration = .init(paletteColors: [.white, NSColor.black.withAlphaComponent(0.6)])
        remove.isBordered = false
        remove.target = self
        remove.action = #selector(removeClicked)
        for view in [picture, remove] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: AttachmentStrip.side),
            heightAnchor.constraint(equalToConstant: AttachmentStrip.side),
            picture.leadingAnchor.constraint(equalTo: leadingAnchor),
            picture.trailingAnchor.constraint(equalTo: trailingAnchor),
            picture.topAnchor.constraint(equalTo: topAnchor),
            picture.bottomAnchor.constraint(equalTo: bottomAnchor),
            remove.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            remove.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
        ])
        let request = QLThumbnailGenerator.Request(fileAt: file, size: CGSize(width: AttachmentStrip.side, height: AttachmentStrip.side),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .all)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] thumbnail, _ in
            guard let image = thumbnail?.nsImage else { return }
            DispatchQueue.main.async { self?.picture.image = image }
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    @objc private func removeClicked() { action() }
}
