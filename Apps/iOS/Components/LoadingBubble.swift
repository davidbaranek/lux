import UIKit

/// A small Liquid Glass capsule with a spinner, at the top of a screen while it loads: what is
/// happening, and under it how far (`detail`).
final class LoadingBubble: UIView {
    private let glass = UIVisualEffectView(effect: UIGlassEffect())
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let warning = UIImageView(image: UIImage(systemName: "exclamationmark.circle.fill"))
    private let label = UILabel()
    private let detailLabel = UILabel()

    init(text: String) {
        super.init(frame: .zero)
        glass.cornerConfiguration = .capsule()
        // hidden until `set(visible:)`: the capsule fades, not the view, whose alpha a navigation
        // bar sets back to 1 as it shows its title view after a push or a pop.
        glass.alpha = 0
        accessibilityElementsHidden = true
        label.text = text
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        detailLabel.font = .preferredFont(forTextStyle: .caption2)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = .tertiaryLabel
        detailLabel.isHidden = true
        spinner.startAnimating()
        warning.tintColor = .systemOrange
        warning.preferredSymbolConfiguration = .init(textStyle: .body)
        warning.isHidden = true
        let lines = UIStackView(arrangedSubviews: [label, detailLabel])
        lines.axis = .vertical
        let stack = UIStackView(arrangedSubviews: [spinner, warning, lines])
        stack.spacing = 8
        stack.alignment = .center
        for view in [glass, stack] as [UIView] { view.translatesAutoresizingMaskIntoConstraints = false }
        addSubview(glass)
        glass.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -8),
        ])
        isAccessibilityElement = true
        accessibilityLabel = text
        accessibilityTraits = .updatesFrequently
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    var text: String? {
        get { label.text }
        set {
            label.text = newValue
            updateAccessibility()
        }
    }

    /// How far it is ("64 so far", "12 of 150 chats"); nil hides the line.
    var detail: String? {
        get { detailLabel.text }
        set {
            detailLabel.text = newValue
            detailLabel.isHidden = newValue == nil
            updateAccessibility()
        }
    }

    /// Something for the user to do rather than progress: a sign instead of the spinner.
    var isWarning = false {
        didSet {
            warning.isHidden = !isWarning
            spinner.isHidden = isWarning
        }
    }

    /// What a tap does; nil: the bubble only tells.
    var onTap: (() -> Void)? {
        didSet {
            if onTap != nil, gestureRecognizers?.isEmpty ?? true {
                addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
            }
            accessibilityTraits = onTap == nil ? .updatesFrequently : [.updatesFrequently, .button]
        }
    }

    @objc private func tapped() {
        guard glass.alpha > 0 else { return }
        onTap?()
    }

    private func updateAccessibility() {
        accessibilityLabel = [label.text, detailLabel.text].compactMap { $0 }.joined(separator: ", ")
    }

    /// Fades in or out; shows only after a short wait, so a fast load shows nothing.
    func set(visible: Bool) {
        accessibilityElementsHidden = !visible
        UIView.animate(withDuration: 0.2, delay: visible ? 0.25 : 0, options: [.beginFromCurrentState]) {
            self.glass.alpha = visible ? 1 : 0
        }
    }
}
