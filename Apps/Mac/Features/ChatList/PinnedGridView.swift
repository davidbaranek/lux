import AppKit
import LuxCore

/// The inbox's pinned chats as a grid of pictures above the list, as Messages pins conversations:
/// one row of the table, laid out by hand, four to a line. A click opens the chat; a right click
/// shows its menu.
final class PinnedGridView: NSTableCellView {
    static let reuse = NSUserInterfaceItemIdentifier("pinned-grid")
    static let columns = 4
    /// A tile's picture and name (72 pt) and the gap to the next line.
    static let tileHeight: CGFloat = 84
    /// Room above the grid, under the search field.
    static let top: CGFloat = 14

    /// The height of a grid of `count` chats.
    static func height(for count: Int) -> CGFloat {
        // the last line without its gap: the list starts right under the names.
        top + CGFloat((count + columns - 1) / columns) * tileHeight - 8
    }

    var onOpen: ((ChatRow) -> Void)?
    var menuProvider: ((ChatRow) -> NSMenu?)?
    private var tiles: [PinnedTile] = []

    override var isFlipped: Bool { true }

    func show(_ rows: [ChatRow], images: ImagePipeline?) {
        while tiles.count < rows.count {
            let tile = PinnedTile()
            tile.onOpen = { [weak self] row in self?.onOpen?(row) }
            tile.menuProvider = { [weak self] row in self?.menuProvider?(row) }
            addSubview(tile)
            tiles.append(tile)
        }
        for (index, tile) in tiles.enumerated() {
            tile.isHidden = index >= rows.count
            if index < rows.count { tile.show(rows[index], images: images) }
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = bounds.width / CGFloat(Self.columns)
        for (index, tile) in tiles.enumerated() where !tile.isHidden {
            tile.frame = CGRect(x: CGFloat(index % Self.columns) * width, y: Self.top + CGFloat(index / Self.columns) * Self.tileHeight,
                                width: width, height: Self.tileHeight)
        }
    }
}

/// One pinned chat: its picture, a dot while unread, its name under it.
private final class PinnedTile: NSView {
    static let side: CGFloat = 44
    var onOpen: ((ChatRow) -> Void)?
    var menuProvider: ((ChatRow) -> NSMenu?)?
    private let avatar = AvatarView(side: side)
    private let name = NSTextField(labelWithString: "")
    private let dot = NSView()
    private var row: ChatRow?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        name.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        name.alignment = .center
        name.lineBreakMode = .byTruncatingTail
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        dot.layer?.cornerRadius = 5
        for view in [avatar, name, dot] as [NSView] { addSubview(view) }
        setAccessibilityRole(.button)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(_ row: ChatRow, images: ImagePipeline?) {
        guard row != self.row else { return }
        self.row = row
        avatar.show(row.avatar, name: row.name, members: row.memberAvatars, images: images)
        name.stringValue = row.name
        name.font = row.isUnread ? .boldSystemFont(ofSize: NSFont.smallSystemFontSize) : .systemFont(ofSize: NSFont.smallSystemFontSize)
        dot.isHidden = !row.isUnread || row.isMuted
        setAccessibilityLabel(row.name)
    }

    override func layout() {
        super.layout()
        let x = (bounds.width - Self.side) / 2
        avatar.frame = CGRect(x: x, y: 6, width: Self.side, height: Self.side)
        dot.frame = CGRect(x: x + Self.side - 10, y: 6, width: 10, height: 10)
        name.frame = CGRect(x: 4, y: avatar.frame.maxY + 6, width: bounds.width - 8, height: 16)
    }

    // the tile takes the press: passed on, the table would track the click and keep the release.
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard let row, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onOpen?(row)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        row.flatMap { menuProvider?($0) }
    }

    override func accessibilityPerformPress() -> Bool {
        guard let row else { return false }
        onOpen?(row)
        return true
    }
}
