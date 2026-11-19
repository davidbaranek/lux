import AppKit

/// A small Liquid Glass capsule with a spinner, at the top of a view while it loads.
final class LoadingBubble: NSView {
    private let glass = NSGlassEffectView()
    private let spinner = NSProgressIndicator()
    private let warning = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: nil) ?? NSImage())
    private let label = NSTextField(labelWithString: "")
    /// Its line's width, at most `maxWidth`: a long line is cut short, never widens what holds it.
    private lazy var width = widthAnchor.constraint(equalToConstant: 120)

    /// The widest it may be (the list's width, less a margin).
    var maxWidth: CGFloat = 320 {
        didSet { if maxWidth != oldValue { fit() } }
    }

    private func fit() {
        // the spinner or sign, the gap and the insets around the line.
        let chrome: CGFloat = 12 + 16 + 8 + 14
        width.constant = min(ceil(label.intrinsicContentSize.width) + chrome, max(maxWidth, chrome))
    }

    init(text: String) {
        super.init(frame: .zero)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        label.stringValue = text
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        // within the bubble's width (`fit`), the line gives way, not the spinner.
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        warning.contentTintColor = .systemOrange
        warning.isHidden = true
        let stack = NSStackView(views: [spinner, warning, label])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 14)

        glass.contentView = stack
        glass.cornerRadius = 15
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.heightAnchor.constraint(equalToConstant: 30),
            width,
        ])
        wantsLayer = true
        // hidden, not only clear: it sits over the top of a list, whose rows take the clicks.
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel(text)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Fades in or out; shows only after a short wait, so a fast load shows nothing.
    var text: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            setAccessibilityLabel(newValue)
            fit()
        }
    }

    /// Something for the user to do rather than progress: a sign instead of the spinner.
    var isWarning = false {
        didSet {
            warning.isHidden = !isWarning
            spinner.isHidden = isWarning
        }
    }

    /// What a click does; nil: the bubble only tells.
    var onClick: (() -> Void)? {
        didSet {
            if onClick != nil, gestureRecognizers.isEmpty {
                addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
            }
            setAccessibilityRole(onClick == nil ? .progressIndicator : .button)
        }
    }

    @objc private func clicked() { onClick?() }

    /// Shows (after a moment, so a quick step shows nothing) or hides the bubble; the newest call wins.
    func set(visible: Bool) {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(fadeIn), object: nil)
        if visible { perform(#selector(fadeIn), with: nil, afterDelay: 0.25) } else { fade(in: false, duration: 0.2) }
    }

    @objc private func fadeIn() { fade(in: true, duration: 0.2) }
}
