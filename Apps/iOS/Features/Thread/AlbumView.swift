import LuxCore
import UIKit

/// Photos sent together, as one picture: a grid of square tiles with rounded outer corners, a
/// play mark on videos. Tiles are reused as albums change; laid out from the precomputed rects.
final class AlbumView: UIView {
    /// A tile was tapped: its index in the album, and the tile to grow from.
    var onTap: ((Int, UIView) -> Void)?
    private var tiles: [RemoteImageView] = []
    private var badges: [UIImageView] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 18
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(_ items: [MessageItem.AlbumItem], tiles frames: [CGRect], images: ImagePipeline?, scale: CGFloat) {
        while tiles.count < items.count {
            let tile = RemoteImageView()
            tile.contentMode = .scaleAspectFill
            tile.clipsToBounds = true
            tile.backgroundColor = .tertiarySystemFill
            tile.isUserInteractionEnabled = true
            tile.tag = tiles.count
            tile.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
            let badge = UIImageView(image: UIImage(systemName: "play.circle.fill"))
            badge.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 28)
                .applying(UIImage.SymbolConfiguration(paletteColors: [.white, UIColor.black.withAlphaComponent(0.4)]))
            tile.addSubview(badge)
            addSubview(tile)
            tiles.append(tile)
            badges.append(badge)
        }
        for (index, tile) in tiles.enumerated() {
            guard index < items.count, index < frames.count else {
                tile.isHidden = true
                continue
            }
            tile.isHidden = false
            tile.frame = frames[index]
            tile.show(items[index].photo.ref, pixels: Int(frames[index].width * scale), images: images)
            badges[index].isHidden = items[index].video == nil
            badges[index].sizeToFit()
            badges[index].center = CGPoint(x: frames[index].width / 2, y: frames[index].height / 2)
            tile.accessibilityLabel = items[index].video == nil ? String(localized: "Photo") : String(localized: "Video")
            tile.isAccessibilityElement = true
            tile.accessibilityTraits = .button
        }
    }

    @objc private func tapped(_ tap: UITapGestureRecognizer) {
        guard let tile = tap.view else { return }
        onTap?(tile.tag, tile)
    }
}
