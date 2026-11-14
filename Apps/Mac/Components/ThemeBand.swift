import AppKit
import LuxCore

/// A place's colour over the top of the sidebar's chat list: a soft band of the accent on the
/// sidebar's material that fades out a little below the search field. Neutral draws nothing.
final class ThemeBand: NSView {
    /// How far down the colour reaches.
    static let height: CGFloat = 300

    private let gradient = CAGradientLayer()

    var theme = PlaceTheme.neutral {
        didSet { if theme != oldValue { needsDisplay = true } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // the layer's origin is at the bottom: the colour starts at the top edge.
        gradient.startPoint = CGPoint(x: 0.5, y: 1)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        gradient.locations = [0, 0.35, 0.7, 1]
        layer?.addSublayer(gradient)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        var colors: [CGColor]?
        effectiveAppearance.performAsCurrentDrawingAppearance {
            guard let color = theme.color else { return }
            // stronger in the dark, where a faint tint disappears; an ease-out so the band has no edge.
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let top: CGFloat = dark ? 0.30 : 0.20
            colors = [top, top * 0.55, top * 0.2, 0].map { color.withAlphaComponent($0).cgColor }
        }
        gradient.colors = colors
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        CATransaction.commit()
    }
}
