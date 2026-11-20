import LuxCore
import QuickLookThumbnailing
import UIKit

/// The files waiting in the composer, in a row above the text: each as Quick Look draws it (a
/// photo's picture, a document's first page, a file's icon), with a button that takes it out. A
/// photo or a PDF opens in Markup when tapped, to draw on it, crop or sign it before it goes.
final class AttachmentStrip: UIView {
    static let side: CGFloat = 64
    var onRemove: ((URL) -> Void)?
    /// A video's quality was chosen in its tile.
    var onVideoQuality: ((URL, VideoQuality) -> Void)?
    /// A photo or a PDF was tapped, in its tile: it opens in Markup.
    var onMarkUp: ((URL, UIView) -> Void)?
    private let scroll = UIScrollView()
    private let row = UIStackView()
    private var tiles: [URL: AttachmentTile] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        scroll.showsHorizontalScrollIndicator = false
        row.axis = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        scroll.addSubview(row)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.heightAnchor.constraint(equalToConstant: Self.side + 8),
            row.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 4),
            row.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -4),
            row.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 6),
            row.heightAnchor.constraint(equalToConstant: Self.side),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// The videos with a choice of quality, and how far their smaller copies are.
    var videos: [URL: PendingVideo] = [:] {
        didSet {
            guard videos != oldValue else { return }
            for (file, tile) in tiles { tile.show(videos[file]) { [weak self] quality in self?.onVideoQuality?(file, quality) } }
        }
    }

    /// The files still on their way to the disk, and how far each has come.
    var arriving: [URL: Double] = [:] {
        didSet {
            guard arriving != oldValue else { return }
            for (file, tile) in tiles { tile.show(arriving: arriving[file]) }
        }
    }
    /// The pictures of files not on disk yet, from where they come (the library): Quick Look has
    /// nothing to draw for them.
    private var previews: [URL: UIImage] = [:]

    func showPreview(_ image: UIImage, of file: URL) {
        previews[file] = image
        tiles[file]?.showPreview(image)
    }

    /// Shows these files, keeping the tiles of those that stay.
    func show(_ files: [URL]) {
        var kept: [URL: AttachmentTile] = [:]
        for file in files {
            kept[file] = tiles[file] ?? AttachmentTile(file: file) { [weak self] in self?.onRemove?(file) } markUp: { [weak self] tile in
                self?.onMarkUp?(file, tile)
            }
        }
        tiles = kept
        previews = previews.filter { kept[$0.key] != nil || arriving[$0.key] != nil }
        let views = files.compactMap { kept[$0] }
        for (file, tile) in kept {
            tile.show(videos[file]) { [weak self] quality in self?.onVideoQuality?(file, quality) }
            tile.show(arriving: arriving[file])
            if let preview = previews[file] { tile.showPreview(preview) }
        }
        if row.arrangedSubviews != views {
            row.arrangedSubviews.forEach { $0.removeFromSuperview() }
            views.forEach(row.addArrangedSubview)
        }
    }
}

private final class AttachmentTile: UIView {
    private let picture = UIImageView()
    private let remove: UIButton
    /// A video's quality, Optimized or Original: a symbol, as the tile is too small for its
    /// word in any language; the word is in its menu, its accessibility label and, held at the
    /// largest text sizes, the large content viewer.
    private let quality: UIButton = {
        var configuration = UIButton.Configuration.filled()
        configuration.baseBackgroundColor = .black.withAlphaComponent(0.6)
        configuration.baseForegroundColor = .white
        configuration.cornerStyle = .capsule
        configuration.buttonSize = .mini
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .caption2, scale: .small)
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 3, leading: 5, bottom: 3, trailing: 5)
        let button = UIButton(configuration: configuration)
        button.showsMenuAsPrimaryAction = true
        // the tile does not grow with the text: the symbol stops at a size that fits it.
        button.maximumContentSizeCategory = .extraExtraLarge
        button.showsLargeContentViewer = true
        button.addInteraction(UILargeContentViewerInteraction())
        button.isHidden = true
        return button
    }()
    private let progress = UIProgressView(progressViewStyle: .bar)
    private var video: PendingVideo?
    /// How far the file has come to the disk; nil once it is there.
    private var arriving: Double?

    init(file: URL, remove: @escaping () -> Void, markUp: @escaping (UIView) -> Void) {
        self.remove = UIButton(primaryAction: UIAction { _ in remove() })
        super.init(frame: .zero)
        if PendingMarkup.canMarkUp(file) {
            let open = UIButton(primaryAction: UIAction { [weak self] _ in
                guard let self else { return }
                markUp(self)
            })
            open.accessibilityLabel = String(localized: "Mark Up \(file.lastPathComponent)")
            open.translatesAutoresizingMaskIntoConstraints = false
            addSubview(open)
            NSLayoutConstraint.activate([
                open.leadingAnchor.constraint(equalTo: leadingAnchor),
                open.trailingAnchor.constraint(equalTo: trailingAnchor),
                open.topAnchor.constraint(equalTo: topAnchor),
                open.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        picture.contentMode = .scaleAspectFill
        picture.layer.cornerRadius = 12
        picture.layer.cornerCurve = .continuous
        picture.clipsToBounds = true
        picture.backgroundColor = .tertiarySystemFill
        self.remove.setImage(UIImage(systemName: "xmark.circle.fill", withConfiguration: UIImage.SymbolConfiguration(paletteColors: [.white, .black.withAlphaComponent(0.6)])),
                             for: .normal)
        self.remove.accessibilityLabel = String(localized: "Remove \(file.lastPathComponent)")
        progress.isHidden = true
        progress.trackTintColor = .black.withAlphaComponent(0.4)
        for view in [picture, quality, progress, self.remove] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: AttachmentStrip.side),
            picture.leadingAnchor.constraint(equalTo: leadingAnchor),
            picture.trailingAnchor.constraint(equalTo: trailingAnchor),
            picture.topAnchor.constraint(equalTo: topAnchor),
            picture.bottomAnchor.constraint(equalTo: bottomAnchor),
            self.remove.topAnchor.constraint(equalTo: topAnchor, constant: -4),
            self.remove.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 4),
            quality.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            quality.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -3),
            quality.bottomAnchor.constraint(equalTo: progress.topAnchor, constant: -2),
            progress.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            progress.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            progress.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
        isAccessibilityElement = false
        let scale = UITraitCollection.current.displayScale
        let request = QLThumbnailGenerator.Request(fileAt: file, size: CGSize(width: AttachmentStrip.side, height: AttachmentStrip.side),
                                                   scale: scale, representationTypes: .all)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] thumbnail, _ in
            guard let image = thumbnail?.uiImage else { return }
            DispatchQueue.main.async { self?.picture.image = image }
        }
    }

    /// The picture of a file not on disk yet (Quick Look has nothing to draw).
    func showPreview(_ image: UIImage) {
        if picture.image == nil { picture.image = image }
    }

    /// A file on its way to the disk: dimmed, with how far it has come.
    func show(arriving: Double?) {
        guard arriving != self.arriving else { return }
        self.arriving = arriving
        picture.alpha = arriving == nil ? 1 : 0.6
        accessibilityValue = arriving.map { String(localized: "Loading, \($0.formatted(.percent.precision(.fractionLength(0))))") }
        showProgress()
    }

    /// The bar shows the file coming, then its smaller copy being made.
    private func showProgress() {
        let share = arriving ?? video?.progress
        progress.isHidden = share == nil
        progress.progress = Float(share ?? 0)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// A video with a choice: its quality, with a menu to change it, and the smaller copy's progress.
    func show(_ video: PendingVideo?, choose: @escaping (VideoQuality) -> Void) {
        guard video != self.video else { return }
        self.video = video
        quality.isHidden = video == nil
        showProgress()
        guard let video else { return }
        let title = video.quality == .optimized ? String(localized: "Optimized") : String(localized: "Original")
        let symbol = UIImage(systemName: video.quality == .optimized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
        quality.configuration?.image = symbol
        quality.accessibilityLabel = String(localized: "Video quality, \(title)")
        quality.largeContentTitle = title
        quality.largeContentImage = symbol
        let optimized = UIAction(title: String(localized: "Optimized"), subtitle: String(localized: "Smaller, sent sooner"),
                                 state: video.quality == .optimized ? .on : .off) { _ in choose(.optimized) }
        let original = UIAction(title: String(localized: "Original"),
                                subtitle: video.canSendOriginal ? String(localized: "As it is") : String(localized: "Larger than the server takes"),
                                attributes: video.canSendOriginal ? [] : .disabled,
                                state: video.quality == .original ? .on : .off) { _ in choose(.original) }
        quality.menu = UIMenu(title: String(localized: "Video Quality"), children: [optimized, original])
    }
}
