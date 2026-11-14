import LuxCore
import UIKit

/// A place's colour behind the top of the chat list: a soft band of the accent that fades out a
/// little below the bar, under the rows, not across the screen. Neutral draws nothing.
final class ThemeBand: UIView {
    /// How far down the colour reaches.
    static let height: CGFloat = 320

    private let gradient = CAGradientLayer()

    var theme = PlaceTheme.neutral {
        didSet { if theme != oldValue { updateColors() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .systemBackground
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        layer.addSublayer(gradient)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) { (band: Self, _) in
            band.updateColors()
        }
        updateColors()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = CGRect(x: 0, y: 0, width: bounds.width, height: min(Self.height, bounds.height))
        CATransaction.commit()
    }

    private func updateColors() {
        guard let color = theme.color?.resolvedColor(with: traitCollection) else {
            gradient.colors = nil
            return
        }
        // stronger in the dark, where a faint tint disappears; an ease-out so the band has no edge.
        let top: CGFloat = traitCollection.userInterfaceStyle == .dark ? 0.32 : 0.22
        gradient.colors = [top, top * 0.55, top * 0.2, 0].map { color.withAlphaComponent($0).cgColor }
        gradient.locations = [0, 0.35, 0.7, 1]
    }
}
