import QuickLookThumbnailing
import UIKit

/// The files waiting in the composer, in a row above the text: each as Quick Look draws it (a
/// photo's picture, a document's first page, a file's icon), with a button that takes it out.
final class AttachmentStrip: UIView {
    static let side: CGFloat = 64
    var onRemove: ((URL) -> Void)?
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

    /// Shows these files, keeping the tiles of those that stay.
    func show(_ files: [URL]) {
        var kept: [URL: AttachmentTile] = [:]
        for file in files {
            kept[file] = tiles[file] ?? AttachmentTile(file: file) { [weak self] in self?.onRemove?(file) }
        }
        tiles = kept
        let views = files.compactMap { kept[$0] }
        if row.arrangedSubviews != views {
            row.arrangedSubviews.forEach { $0.removeFromSuperview() }
            views.forEach(row.addArrangedSubview)
        }
    }
}

private final class AttachmentTile: UIView {
    private let picture = UIImageView()
    private let remove: UIButton

    init(file: URL, remove: @escaping () -> Void) {
        self.remove = UIButton(primaryAction: UIAction { _ in remove() })
        super.init(frame: .zero)
        picture.contentMode = .scaleAspectFill
        picture.layer.cornerRadius = 12
        picture.layer.cornerCurve = .continuous
        picture.clipsToBounds = true
        picture.backgroundColor = .tertiarySystemFill
        self.remove.setImage(UIImage(systemName: "xmark.circle.fill", withConfiguration: UIImage.SymbolConfiguration(paletteColors: [.white, .black.withAlphaComponent(0.6)])),
                             for: .normal)
        self.remove.accessibilityLabel = String(localized: "Remove \(file.lastPathComponent)")
        for view in [picture, self.remove] as [UIView] {
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

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}
