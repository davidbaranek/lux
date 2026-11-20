import AppKit

/// An AI action above the composer's field: its name, working (a spinner), then its result's ✓
/// and ✕ on the right, all in one plain box.
final class ComposerReviewBar: NSStackView {
    /// Its gap from the composer's edges, the same all round.
    static let gap: CGFloat = 6
    /// The composer's glass' corner radius, which its own follows (concentric).
    static let composerRadius: CGFloat = 18
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
        setViews([icon, labels, NSView(), spinner, accept, reject], in: .leading)
        spacing = 8
        // the name and its buttons in one box: a plain fill, as the composer around it is glass.
        edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 10)
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
        super.updateLayer()
        layer?.backgroundColor = NSColor.quaternarySystemFill.cgColor
    }

    override var wantsUpdateLayer: Bool { true }

    private static func round(_ symbol: String, label: String, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage.symbol(symbol, label: label), target: target, action: action)
        button.bezelStyle = .circular
        button.controlSize = .regular
        button.toolTip = label
        return button
    }

    @objc private func accepted() { onAccept?() }
    @objc private func rejected() { onReject?() }
}
