import AppKit
import LuxCore
import QuickLookThumbnailing

/// The files waiting in the composer, in a row above the text: each as Quick Look draws it, with
/// a button that takes it out.
final class AttachmentStrip: NSView {
    static let side: CGFloat = 56
    var onRemove: ((URL) -> Void)?
    /// A video's quality was chosen in its tile.
    var onVideoQuality: ((URL, VideoQuality) -> Void)?
    /// The videos with a choice of quality, and how far their smaller copies are.
    var videos: [URL: PendingVideo] = [:] {
        didSet { if videos != oldValue { showVideos() } }
    }
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
        showVideos()
    }

    private func showVideos() {
        for (file, tile) in tiles { tile.show(videos[file]) { [weak self] quality in self?.onVideoQuality?(file, quality) } }
    }
}

private final class AttachmentTile: NSView {
    private let picture = NSImageView()
    private let remove = NSButton()
    private let action: () -> Void
    /// A video's quality, Optimized or Original (a menu to change it), and how far its smaller copy is.
    private let quality = NSPopUpButton(frame: .zero, pullsDown: true)
    private let progress = NSProgressIndicator()
    private var video: PendingVideo?
    private var choose: ((VideoQuality) -> Void)?

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
        quality.controlSize = .mini
        quality.font = .systemFont(ofSize: NSFont.systemFontSize(for: .mini), weight: .semibold)
        quality.bezelStyle = .push
        quality.isHidden = true
        progress.style = .bar
        progress.controlSize = .mini
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.isHidden = true
        for view in [picture, quality, progress, remove] as [NSView] {
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
            quality.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            quality.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            quality.bottomAnchor.constraint(equalTo: progress.topAnchor, constant: -1),
            progress.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            progress.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            progress.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
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

    /// A video with a choice: its quality, with a menu to change it, and the smaller copy's progress.
    func show(_ video: PendingVideo?, choose: @escaping (VideoQuality) -> Void) {
        self.choose = choose
        guard video != self.video else { return }
        self.video = video
        quality.isHidden = video == nil
        progress.isHidden = video?.progress == nil
        progress.doubleValue = video?.progress ?? 0
        guard let video else { return }
        let menu = NSMenu()
        // a pull-down's first item is its title.
        menu.addItem(withTitle: video.quality == .optimized ? String(localized: "Optimized") : String(localized: "Original"), action: nil, keyEquivalent: "")
        let optimized = NSMenuItem(title: String(localized: "Optimized"), action: #selector(chooseOptimized), keyEquivalent: "")
        // what each sends: its lines and bytes, and how much smaller the copy is.
        optimized.subtitle = video.optimizedDetail
        optimized.state = video.quality == .optimized ? .on : .off
        let original = NSMenuItem(title: String(localized: "Original"), action: video.canSendOriginal ? #selector(chooseOriginal) : nil, keyEquivalent: "")
        original.subtitle = video.originalDetail
        original.state = video.quality == .original ? .on : .off
        for item in [optimized, original] {
            item.target = self
            menu.addItem(item)
        }
        quality.menu = menu
        quality.setAccessibilityLabel(String(localized: "Video quality"))
    }

    @objc private func chooseOptimized() { choose?(.optimized) }
    @objc private func chooseOriginal() { choose?(.original) }
}
