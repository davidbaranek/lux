import LuxCore
import UIKit

/// A place's colour at the top of the chat list: a soft band of the accent behind the first rows
/// that scrolls away with them, not across the screen. It reaches up past the top too, so pulling
/// the list down shows the colour, not a gap. Neutral draws nothing.
final class ThemeBand: UIView {
    /// How far down the colour reaches from the top of the list's content.
    static let height: CGFloat = 320
    /// How far it reaches above, for a list pulled down.
    static let overscroll: CGFloat = 600

    private let gradient = CAGradientLayer()

    var theme = PlaceTheme.neutral {
        didSet { if theme != oldValue { updateColors() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        // behind the rows, which are clear at rest.
        layer.zPosition = -1
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        layer.addSublayer(gradient)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) { (band: Self, _) in
            band.updateColors()
        }
        updateColors()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Places the band at the top of `scrollView`'s content, the bar's height above it included.
    func place(in scrollView: UIScrollView) {
        let top = -scrollView.adjustedContentInset.top
        frame = CGRect(x: 0, y: top - Self.overscroll, width: scrollView.bounds.width,
                       height: Self.overscroll + Self.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        CATransaction.commit()
    }

    private func updateColors() {
        guard let color = theme.color?.resolvedColor(with: traitCollection) else {
            gradient.colors = nil
            return
        }
        // a little stronger in the dark, where a faint tint disappears; an ease-out so the band
        // has no edge.
        let top: CGFloat = traitCollection.userInterfaceStyle == .dark ? 0.3 : 0.2
        let start = Self.overscroll / (Self.overscroll + Self.height)
        let fade: (CGFloat) -> NSNumber = { NSNumber(value: Double(start + (1 - start) * $0)) }
        gradient.colors = [top, top, top * 0.55, top * 0.2, 0].map { color.withAlphaComponent($0).cgColor }
        gradient.locations = [0, fade(0), fade(0.35), fade(0.7), 1]
    }
}
