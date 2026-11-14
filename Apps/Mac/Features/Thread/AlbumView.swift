import AppKit
import LuxCore

/// Photos sent together, as one picture: a grid of square tiles with rounded outer corners, a
/// play mark on videos. Tiles are reused as albums change; laid out from the precomputed rects.
final class AlbumView: NSView {
    /// A tile was clicked: its index in the album, and the tile.
    var onTap: ((Int, NSView) -> Void)?
    private var tiles: [RemoteImageView] = []
    private var badges: [NSImageView] = []

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(_ items: [MessageItem.AlbumItem], tiles frames: [CGRect], images: ImagePipeline?) {
        while tiles.count < items.count {
            let tile = RemoteImageView()
            tile.wantsLayer = true
            tile.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
            tile.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
            let badge = NSImageView(image: NSImage.symbol("play.circle.fill"))
            badge.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 24, weight: .regular)
                .applying(.init(paletteColors: [.white, NSColor.black.withAlphaComponent(0.4)]))
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
            tile.show(items[index].photo.ref, pixels: Int(frames[index].width * 2), images: images)
            let badge = badges[index]
            badge.isHidden = items[index].video == nil
            let size = badge.intrinsicContentSize
            badge.frame = CGRect(x: (frames[index].width - size.width) / 2, y: (frames[index].height - size.height) / 2,
                                 width: size.width, height: size.height)
        }
    }

    /// Where a tile is on screen, for Quick Look's zoom.
    func frameOnScreen(of index: Int) -> NSRect? {
        guard index < tiles.count, let window else { return nil }
        return window.convertToScreen(tiles[index].convert(tiles[index].bounds, to: nil))
    }

    @objc private func clicked(_ click: NSClickGestureRecognizer) {
        guard let tile = click.view, let index = tiles.firstIndex(where: { $0 === tile }) else { return }
        onTap?(index, tile)
    }
}
