import AppKit
import LuxCore

/// The photos a search found, as a grid of square thumbnails in one row of the results; a click
/// opens the photo's chat at it.
final class PhotoGridView: NSTableCellView {
    static let reuse = NSUserInterfaceItemIdentifier("photo-grid")
    /// A thumbnail at least this wide: the row fits as many as it can, then they grow to fill it.
    private static let minSide: CGFloat = 76
    private static let spacing: CGFloat = 4

    /// Opens the photo's chat at it.
    var onOpen: ((FoundPhoto) -> Void)?
    /// The grid got another width (the table's cell is narrower than the table): its height
    /// follows from it.
    var onWidth: ((CGFloat) -> Void)?
    private var reportedWidth: CGFloat = 0

    private var photos: [FoundPhoto] = []
    private var tiles: [NSButton] = []
    private var images: ImagePipeline?

    /// The height the grid takes at `width` for `count` photos.
    static func height(for count: Int, width: CGFloat) -> CGFloat {
        let rows = (count + columns(width) - 1) / columns(width)
        return CGFloat(rows) * (side(width) + spacing) - spacing + 2 * spacing
    }

    static func columns(_ width: CGFloat) -> Int {
        max(1, Int((width + spacing) / (minSide + spacing)))
    }

    /// The thumbnails' side at `width`: the row edge to edge, as the rows above and below it.
    private static func side(_ width: CGFloat) -> CGFloat {
        let columns = CGFloat(columns(width))
        return max(1, floor((width - spacing * (columns - 1)) / columns))
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
            let pixels = Int(Self.side(bounds.width > 0 ? bounds.width : 300) * (window?.backingScaleFactor ?? 2))
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
        if bounds.width > 0, bounds.width != reportedWidth {
            reportedWidth = bounds.width
            onWidth?(bounds.width)
        }
        let columns = Self.columns(bounds.width)
        let side = Self.side(bounds.width)
        // what rounding leaves over goes to both sides, so the grid stays centred.
        let left = floor((bounds.width - CGFloat(columns) * side - CGFloat(columns - 1) * Self.spacing) / 2)
        for (index, tile) in tiles.enumerated() where index < photos.count {
            let (row, column) = (index / columns, index % columns)
            // flipped or not, the first row is at the top.
            let y = isFlipped ? Self.spacing + CGFloat(row) * (side + Self.spacing)
                : bounds.height - Self.spacing - CGFloat(row + 1) * side - CGFloat(row) * Self.spacing
            tile.frame = CGRect(x: left + CGFloat(column) * (side + Self.spacing), y: y, width: side, height: side)
        }
    }

    /// The thumbnail filling its square (cropped, as Photos shows it).
    private static func filled(_ image: CGImage) -> NSImage {
        let shorter = min(image.width, image.height)
        let square = CGRect(x: (image.width - shorter) / 2, y: (image.height - shorter) / 2, width: shorter, height: shorter)
        let cropped = image.cropping(to: square) ?? image
        return NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
    }

    @objc private func open(_ tile: NSButton) {
        guard photos.indices.contains(tile.tag) else { return }
        onOpen?(photos[tile.tag])
    }
}
