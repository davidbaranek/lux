import AppKit
import LuxCore

/// A file in a bubble: its kind's symbol in a rounded square, its name (one line, truncated in
/// the middle) and its size or length under it. Placed by hand.
final class FileRowView: NSView {
    private let tile = NSView()
    private let symbol = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let metrics = BubbleMetrics()

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        tile.wantsLayer = true
        tile.layer?.cornerRadius = 8
        tile.layer?.cornerCurve = .continuous
        symbol.symbolConfiguration = .init(pointSize: 16, weight: .medium)
        name.lineBreakMode = .byTruncatingMiddle
        for view in [tile, symbol, name, detail] as [NSView] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(_ file: MessageItem.File, own: Bool, text: MessageText) {
        let ink: NSColor = own ? .white : .labelColor
        tile.layer?.backgroundColor = (own ? NSColor.white.withAlphaComponent(0.22) : NSColor.quaternaryLabelColor).cgColor
        symbol.image = NSImage(systemSymbolName: file.symbol, accessibilityDescription: nil)
        symbol.contentTintColor = ink
        name.font = text.fileName
        name.textColor = ink
        name.stringValue = file.name
        detail.font = text.footer
        detail.textColor = own ? NSColor.white.withAlphaComponent(0.75) : .secondaryLabelColor
        detail.stringValue = file.detailText
        setAccessibilityLabel("\(file.name), \(file.detailText)")
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let side = metrics.fileIconSide
        tile.frame = CGRect(x: 0, y: (bounds.height - side) / 2, width: side, height: side)
        symbol.frame = tile.frame
        let x = side + metrics.fileGap, width = max(0, bounds.width - x)
        let nameHeight = ceil(name.intrinsicContentSize.height), detailHeight = ceil(detail.intrinsicContentSize.height)
        let top = (bounds.height - nameHeight - detailHeight) / 2
        name.frame = CGRect(x: x, y: top, width: width, height: nameHeight)
        detail.frame = CGRect(x: x, y: top + nameHeight, width: width, height: detailHeight)
    }
}

/// Over a video's poster: a play symbol in its middle and its length in a corner.
final class VideoBadgeView: NSView {
    private let play = NSImageView()
    private let length = NSTextField(labelWithString: "")
    private let lengthBackground = NSView()

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        play.image = NSImage(systemSymbolName: "play.circle.fill", accessibilityDescription: nil)
        play.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 36, weight: .regular)
            .applying(.init(paletteColors: [.white, NSColor.black.withAlphaComponent(0.4)]))
        length.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        length.textColor = .white
        lengthBackground.wantsLayer = true
        lengthBackground.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        lengthBackground.layer?.cornerRadius = 8
        for view in [play, lengthBackground, length] as [NSView] { addSubview(view) }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Clicks go to the picture under it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(duration: String?) {
        length.stringValue = duration ?? ""
        length.isHidden = duration == nil
        lengthBackground.isHidden = duration == nil
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let size = play.intrinsicContentSize
        play.frame = CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        let text = length.intrinsicContentSize
        let background = CGRect(x: bounds.width - text.width - 12 - 6, y: bounds.height - 16 - 6, width: text.width + 12, height: 16)
        lengthBackground.frame = background
        length.frame = CGRect(x: background.minX + 6, y: background.midY - text.height / 2, width: text.width, height: text.height)
    }
}
