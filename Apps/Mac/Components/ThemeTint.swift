import AppKit
import LuxCore

/// A place's colour as a wash of the accent over what is behind it: over the whole sidebar, the
/// rail and the chat list alike, so the material still shows through; and, much fainter, behind the
/// chat pane. Neutral draws nothing.
final class ThemeTint: NSView {
    var theme = PlaceTheme.neutral {
        didSet { if theme != oldValue { needsDisplay = true } }
    }

    /// How strong the wash is in light and in the dark.
    private let strength: (light: CGFloat, dark: CGFloat)

    /// Light and airy over the light material; a little stronger in the dark, where a faint wash
    /// disappears.
    static let sidebar = (light: CGFloat(0.14), dark: CGFloat(0.22))
    /// Behind a chat's messages: barely there, so the bubbles keep their contrast.
    static let chat = (light: CGFloat(0.02), dark: CGFloat(0.035))

    init(strength: (light: CGFloat, dark: CGFloat)) {
        self.strength = strength
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        var color: CGColor?
        effectiveAppearance.performAsCurrentDrawingAppearance {
            guard let wash = theme.wash else { return }
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            color = wash.withAlphaComponent(dark ? strength.dark : strength.light).cgColor
        }
        layer?.backgroundColor = color
    }
}
