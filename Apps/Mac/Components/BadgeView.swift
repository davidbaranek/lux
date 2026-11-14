import AppKit

final class BadgeView: NSView {
    var count = 0 { didSet { label.stringValue = count > 0 ? String(count) : ""; invalidateIntrinsicContentSize() } }
    var muted = false { didSet { needsDisplay = true } }
    /// The badge's colour when not muted: the accent in the list, red on the rail.
    var color: NSColor = .controlAccentColor { didSet { needsDisplay = true } }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = (muted ? NSColor.systemGray : color).cgColor
    }
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: max(label.intrinsicContentSize.width + 10, 18), height: 18)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }
}
