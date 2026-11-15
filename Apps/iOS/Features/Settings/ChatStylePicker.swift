import LuxCore
import UIKit

/// Bubbles or plain rows, side by side: each a small drawing of a chat in that style over its
/// name, the chosen one ringed in the accent colour.
final class ChatStylePicker: UIView {
    private var tiles: [ChatStyle: Tile] = [:]
    var onChoose: ((ChatStyle) -> Void)?

    var style: ChatStyle {
        didSet { for (key, tile) in tiles { tile.isSelected = key == style } }
    }

    init(style: ChatStyle) {
        self.style = style
        super.init(frame: .zero)
        let row = UIStackView()
        row.axis = .horizontal
        row.distribution = .fillEqually
        row.spacing = 12
        for option in ChatStyle.allCases {
            let tile = Tile(style: option)
            tile.isSelected = option == style
            tile.addAction(UIAction { [weak self] _ in
                guard let self, self.style != option else { return }
                self.style = option
                onChoose?(option)
            }, for: .primaryActionTriggered)
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

    /// One choice: its drawing, its name and a line on it, a check under them.
    private final class Tile: UIControl {
        private let sketch: Sketch
        private let check = UIImageView()

        override var isSelected: Bool {
            didSet { update() }
        }

        override var isHighlighted: Bool {
            didSet { alpha = isHighlighted ? 0.6 : 1 }
        }

        init(style: ChatStyle) {
            sketch = Sketch(style: style)
            super.init(frame: .zero)
            let title = UILabel()
            title.text = style.title
            title.font = .preferredFont(forTextStyle: .subheadline).bold
            title.adjustsFontForContentSizeCategory = true
            let subtitle = UILabel()
            subtitle.text = style.subtitle
            subtitle.font = .preferredFont(forTextStyle: .caption1)
            subtitle.adjustsFontForContentSizeCategory = true
            subtitle.textColor = .secondaryLabel
            subtitle.numberOfLines = 0
            subtitle.textAlignment = .center
            check.preferredSymbolConfiguration = .init(textStyle: .title3)
            let stack = UIStackView(arrangedSubviews: [sketch, title, subtitle, check])
            stack.axis = .vertical
            stack.alignment = .center
            stack.spacing = 6
            stack.setCustomSpacing(10, after: sketch)
            stack.isUserInteractionEnabled = false
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: trailingAnchor),
                stack.topAnchor.constraint(equalTo: topAnchor),
                stack.bottomAnchor.constraint(equalTo: bottomAnchor),
                sketch.widthAnchor.constraint(equalTo: widthAnchor),
                sketch.heightAnchor.constraint(equalTo: sketch.widthAnchor, multiplier: 0.75),
            ])
            isAccessibilityElement = true
            accessibilityLabel = style.title
            accessibilityHint = style.subtitle
            update()
        }

        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

        private func update() {
            sketch.isChosen = isSelected
            check.image = UIImage(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            check.tintColor = isSelected ? .tintColor : .tertiaryLabel
            accessibilityTraits = isSelected ? [.button, .selected] : .button
        }
    }

    /// The drawing (`ChatStyleSketch`) in the system's colours, ringed while chosen.
    private final class Sketch: UIView {
        private let style: ChatStyle
        var isChosen = false {
            didSet { if isChosen != oldValue { updateRing() } }
        }

        init(style: ChatStyle) {
            self.style = style
            super.init(frame: .zero)
            isOpaque = false
            contentMode = .redraw
            layer.cornerRadius = 12
            layer.cornerCurve = .continuous
            registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
                self.setNeedsDisplay()
                self.updateRing()
            }
            updateRing()
        }

        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

        override func tintColorDidChange() {
            super.tintColorDidChange()
            setNeedsDisplay()
            updateRing()
        }

        private func updateRing() {
            layer.borderWidth = isChosen ? 2.5 : 1
            layer.borderColor = (isChosen ? tintColor : UIColor.separator).resolvedColor(with: traitCollection).cgColor
        }

        override func draw(_ rect: CGRect) {
            guard let context = UIGraphicsGetCurrentContext() else { return }
            func cg(_ color: UIColor) -> CGColor { color.resolvedColor(with: traitCollection).cgColor }
            let palette = ChatStyleSketch.Palette(background: cg(.systemBackground), incoming: cg(.systemGray5), own: cg(tintColor),
                                                  ink: cg(.label), inkOnOwn: cg(UIColor.white.withAlphaComponent(0.8)))
            ChatStyleSketch.draw(style, in: context, rect: bounds.insetBy(dx: 1, dy: 1), palette: palette)
        }
    }
}
