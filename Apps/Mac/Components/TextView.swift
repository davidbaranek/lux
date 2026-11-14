import AppKit

/// A container whose subviews are placed from the top, as `MessageLayout` gives them.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Draws a string in its bounds, wrapped, exactly as `MessageText` measured it.
final class TextView: NSView {
    nonisolated static let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine]
    private var text: NSAttributedString?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        // a growing text (a caption unfolding) shows its top as it was while the view grows,
        // not its drawing stretched.
        layerContentsPlacement = .top
    }

    /// Another size wraps the text otherwise: drawn again (the layer would keep the old drawing).
    override func setFrameSize(_ newSize: NSSize) {
        let resized = newSize != frame.size
        super.setFrameSize(newSize)
        if resized { needsDisplay = true }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func set(_ string: String, font: NSFont, color: NSColor) {
        set(NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color]))
    }

    /// Text with its own attributes (links underlined); measured with the same font as plain text.
    func set(_ attributed: NSAttributedString) {
        guard attributed != text else { return }
        text = attributed
        needsDisplay = true
    }

    /// The character at a point of the view, for a click on a link: TextKit built only when asked.
    func characterIndex(at point: NSPoint) -> Int {
        guard let text else { return NSNotFound }
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: bounds.size)
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        let glyph = manager.glyphIndex(for: point, in: container)
        guard manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(point) else { return NSNotFound }
        return manager.characterIndexForGlyph(at: glyph)
    }

    override func draw(_ dirtyRect: NSRect) {
        text?.draw(with: bounds, options: Self.options)
    }

    /// Light and dark: the dynamic colours resolve again.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
