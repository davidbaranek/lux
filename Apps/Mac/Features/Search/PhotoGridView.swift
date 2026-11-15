import AppKit
import LuxCore

/// The photos a search found, as a grid of square thumbnails in one row of the results; a click
/// opens the photo's chat at it.
final class PhotoGridView: NSTableCellView {
    static let reuse = NSUserInterfaceItemIdentifier("photo-grid")
    private static let side: CGFloat = 92
    private static let spacing: CGFloat = 4
    private static let inset: CGFloat = 12

    /// Opens the photo's chat at it.
    var onOpen: ((FoundPhoto) -> Void)?

    private var photos: [FoundPhoto] = []
    private var tiles: [NSButton] = []
    private var images: ImagePipeline?

    /// The height the grid takes at `width` for `count` photos.
    static func height(for count: Int, width: CGFloat) -> CGFloat {
        let rows = (count + columns(width) - 1) / columns(width)
        return CGFloat(rows) * (side + spacing) - spacing + 2 * spacing
    }

    private static func columns(_ width: CGFloat) -> Int {
        max(1, Int((width - 2 * inset + spacing) / (side + spacing)))
    }

    func show(_ photos: [FoundPhoto], images: ImagePipeline?) {
        identifier = Self.reuse
        self.photos = photos
        self.images = images
        while tiles.count < photos.count {
            let tile = NSButton(title: "", target: self, action: #selector(open(_:)))
            tile.isBordered = false
            tile.imageScaling = .scaleProportionallyUpOrDown
            tile.wantsLayer = true
            tile.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
            tile.layer?.masksToBounds = true
            tile.layer?.cornerRadius = 4
            addSubview(tile)
            tiles.append(tile)
        }
        for (index, tile) in tiles.enumerated() {
            tile.isHidden = index >= photos.count
            tile.tag = index
            guard index < photos.count else { continue }
            let photo = photos[index]
            tile.image = nil
            tile.setAccessibilityLabel(String(localized: "Photo from \(photo.isOwn ? String(localized: "you") : photo.senderName) in \(photo.chat.name)"))
            tile.toolTip = photo.chat.name
            let ref = photo.image
            let pixels = Int(Self.side * (window?.backingScaleFactor ?? 2))
            if let cached = images?.cached(ref, pixels: pixels) {
                tile.image = Self.filled(cached)
                continue
            }
            Task { [weak self, weak tile] in
                guard let image = await images?.image(ref, pixels: pixels),
                      let self, let tile, self.photos.indices.contains(tile.tag), self.photos[tile.tag].image == ref else { return }
                tile.image = Self.filled(image)
            }
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let columns = Self.columns(bounds.width)
        for (index, tile) in tiles.enumerated() where index < photos.count {
            let (row, column) = (index / columns, index % columns)
            // flipped or not, the first row is at the top.
            let y = isFlipped ? Self.spacing + CGFloat(row) * (Self.side + Self.spacing)
                : bounds.height - Self.spacing - CGFloat(row + 1) * Self.side - CGFloat(row) * Self.spacing
            tile.frame = CGRect(x: Self.inset + CGFloat(column) * (Self.side + Self.spacing), y: y, width: Self.side, height: Self.side)
        }
    }

    /// The thumbnail filling its square (cropped, as Photos shows it).
    private static func filled(_ image: CGImage) -> NSImage {
        let shorter = min(image.width, image.height)
        let square = CGRect(x: (image.width - shorter) / 2, y: (image.height - shorter) / 2, width: shorter, height: shorter)
        let cropped = image.cropping(to: square) ?? image
        return NSImage(cgImage: cropped, size: NSSize(width: side, height: side))
    }

    @objc private func open(_ tile: NSButton) {
        guard photos.indices.contains(tile.tag) else { return }
        onOpen?(photos[tile.tag])
    }
}
