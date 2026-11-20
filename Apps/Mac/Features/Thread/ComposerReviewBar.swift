import AppKit

/// An AI action above the composer's field: its name, working (a spinner), then its result's ✓
/// and ✕ on the right, all in one plain box. The box is a view of its own, its row pinned inside it
/// with fixed insets, so nothing in the composer's stack squeezes the box under its buttons.
final class ComposerReviewBar: NSView {
    /// Its gap from the composer's edges, the same all round.
    static let gap: CGFloat = 6
    /// The composer's glass' corner radius, which its own follows (concentric).
    static let composerRadius: CGFloat = 18
    /// The buttons' inset from the box's edges.
    static let inset: CGFloat = 6
    var onAccept: (() -> Void)?
    var onReject: (() -> Void)?
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let note = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    /// ✓ and ✕, round.
    private lazy var accept = Self.round("checkmark", label: String(localized: "Apply"), target: self, action: #selector(accepted))
    private lazy var reject = Self.round("xmark", label: String(localized: "Cancel"), target: self, action: #selector(rejected))

    init() {
        super.init(frame: .zero)
        icon.contentTintColor = .secondaryLabelColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(textStyle: .body)
        title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        title.textColor = .labelColor
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let labels = NSStackView(views: [title, note])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 0
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [icon, labels, spacer, spinner, accept, reject])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.setCustomSpacing(6, after: accept)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        // the name and its buttons in one box: a plain fill, as the composer around it is glass.
        // The buttons keep the same inset from the box's top, bottom and end.
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
            row.topAnchor.constraint(equalTo: topAnchor, constant: Self.inset),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.inset),
            heightAnchor.constraint(greaterThanOrEqualToConstant: RoundButton.size + 2 * Self.inset),
        ])
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
        wantsLayer = true
        layer?.cornerRadius = Self.composerRadius - Self.gap
        layer?.cornerCurve = .continuous
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func showWorking(symbol: String, title: String) {
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        self.title.stringValue = title
        note.stringValue = ""
        note.isHidden = true
        accept.isHidden = true
        spinner.startAnimation(nil)
        setAccessibilityLabel(title)
    }

    func showResult(note text: String?, canApply: Bool) {
        spinner.stopAnimation(nil)
        note.stringValue = text ?? ""
        note.isHidden = text == nil
        accept.isHidden = !canApply
    }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.tertiarySystemFill.cgColor
    }

    override var wantsUpdateLayer: Bool { true }

    private static func round(_ symbol: String, label: String, target: AnyObject, action: Selector) -> NSButton {
        let button = RoundButton(image: NSImage.symbol(symbol, label: label), target: target, action: action)
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        button.contentTintColor = symbol == "checkmark" ? .labelColor : .secondaryLabelColor
        button.toolTip = label
        return button
    }

    @objc private func accepted() { onAccept?() }
    @objc private func rejected() { onReject?() }
}

/// A round button with a plain fill, a size of its own: no bezel, whose frame is larger than what
/// it draws, so the box's insets hold.
private final class RoundButton: NSButton {
    static let size: CGFloat = 28

    convenience init(image: NSImage, target: AnyObject, action: Selector) {
        self.init(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        self.image = image
        self.target = target
        self.action = action
        isBordered = false
        imagePosition = .imageOnly
        wantsLayer = true
        layer?.cornerRadius = Self.size / 2
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.size),
            heightAnchor.constraint(equalToConstant: Self.size),
        ])
    }

    override var wantsUpdateLayer: Bool { true }

    override var isHighlighted: Bool {
        didSet { needsDisplay = true }
    }

    override func updateLayer() {
        layer?.backgroundColor = (isHighlighted ? NSColor.tertiaryLabelColor : NSColor.secondarySystemFill).cgColor
    }
}
