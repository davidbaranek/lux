import AppKit
import LuxCore

/// A place's colour over the whole sidebar, the rail and the chat list alike: a wash of the
/// accent on the sidebar's material, so the material still shows through. Neutral draws nothing.
final class ThemeTint: NSView {
    var theme = PlaceTheme.neutral {
        didSet { if theme != oldValue { needsDisplay = true } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        var color: CGColor?
        effectiveAppearance.performAsCurrentDrawingAppearance {
            guard let wash = theme.wash else { return }
            // light and airy over the light material; a little stronger in the dark, where a faint
            // wash disappears.
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            color = wash.withAlphaComponent(dark ? 0.22 : 0.14).cgColor
        }
        layer?.backgroundColor = color
    }
}
