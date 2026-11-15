import AppKit
import LuxCore

/// Bubbles or plain rows, side by side: each a small drawing of a chat in that style over its
/// name, the chosen one ringed in the accent colour and its radio button on.
final class ChatStylePicker: NSView {
    private var tiles: [ChatStyle: Tile] = [:]
    var onChoose: ((ChatStyle) -> Void)?

    var style: ChatStyle {
        didSet { for (key, tile) in tiles { tile.isChosen = key == style } }
    }

    init(style: ChatStyle) {
        self.style = style
        super.init(frame: .zero)
        let row = NSStackView()
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.spacing = 16
        for option in ChatStyle.allCases {
            let tile = Tile(style: option) { [weak self] in
                guard let self, self.style != option else { return }
                self.style = option
                onChoose?(option)
            }
            tile.isChosen = option == style
            tiles[option] = tile
            row.addArrangedSubview(tile)
        }
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// One choice: its drawing over a radio button with its name, and a line on it.
    private final class Tile: NSStackView {
        private let sketch: Sketch
        private let radio: NSButton
        private let choose: () -> Void

        var isChosen = false {
            didSet {
                sketch.isChosen = isChosen
                radio.state = isChosen ? .on : .off
            }
        }

        init(style: ChatStyle, choose: @escaping () -> Void) {
            self.choose = choose
            sketch = Sketch(style: style)
            radio = NSButton(radioButtonWithTitle: style.title, target: nil, action: nil)
            super.init(frame: .zero)
            radio.target = self
            radio.action = #selector(chosen)
            let subtitle = NSTextField(labelWithString: style.subtitle)
            subtitle.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            subtitle.textColor = .secondaryLabelColor
            orientation = .vertical
            alignment = .centerX
            spacing = 6
            for view in [sketch, radio, subtitle] as [NSView] { addArrangedSubview(view) }
            setCustomSpacing(10, after: sketch)
            NSLayoutConstraint.activate([
                sketch.widthAnchor.constraint(equalToConstant: 160),
                sketch.heightAnchor.constraint(equalToConstant: 120),
            ])
            sketch.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(chosen)))
        }

        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

        @objc private func chosen() {
            choose()
            // a radio button turns itself on: the picker decides.
            radio.state = isChosen ? .on : .off
        }
    }

    /// The drawing (`ChatStyleSketch`) in the system's colours, ringed while chosen.
    private final class Sketch: NSView {
        private let style: ChatStyle
        var isChosen = false {
            didSet { if isChosen != oldValue { needsDisplay = true } }
        }

        init(style: ChatStyle) {
            self.style = style
            super.init(frame: .zero)
            setAccessibilityElement(false)
        }

        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

        override var isFlipped: Bool { true }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            let palette = ChatStyleSketch.Palette(background: NSColor.textBackgroundColor.cgColor, incoming: NSColor.incomingBubble.cgColor,
                                                  own: NSColor.controlAccentColor.cgColor, ink: NSColor.labelColor.cgColor,
                                                  inkOnOwn: NSColor.white.withAlphaComponent(0.8).cgColor)
            let ring = isChosen ? CGFloat(3) : 1
            ChatStyleSketch.draw(style, in: context, rect: bounds.insetBy(dx: ring, dy: ring), palette: palette)
            let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: ring / 2, dy: ring / 2), xRadius: 11, yRadius: 11)
            outline.lineWidth = ring
            (isChosen ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
            outline.stroke()
        }
    }
}
