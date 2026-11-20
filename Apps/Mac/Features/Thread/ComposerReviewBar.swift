import AppKit

/// An AI action above the composer's field: its name, working (a spinner), then its result's ✓
/// and ✕ on the right, all in one plain box.
final class ComposerReviewBar: NSStackView {
    var onAccept: (() -> Void)?
    var onReject: (() -> Void)?
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let note = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    /// ✓ and ✕ in one box, as a Mac groups two actions: a momentary segmented control.
    private lazy var buttons = NSSegmentedControl(
        images: [NSImage.symbol("checkmark", label: String(localized: "Apply")),
                 NSImage.symbol("xmark", label: String(localized: "Cancel"))],
        trackingMode: .momentary, target: self, action: #selector(clicked))

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
        buttons.segmentStyle = .rounded
        buttons.setToolTip(String(localized: "Apply"), forSegment: 0)
        buttons.setToolTip(String(localized: "Cancel"), forSegment: 1)
        let labels = NSStackView(views: [title, note])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 0
        setViews([icon, labels, NSView(), spinner, buttons], in: .leading)
        spacing = 8
        // the name and its buttons in one box: a plain fill, as the composer around it is glass.
        edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 6)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func showWorking(symbol: String, title: String) {
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        self.title.stringValue = title
        note.stringValue = ""
        note.isHidden = true
        buttons.setEnabled(false, forSegment: 0)
        spinner.startAnimation(nil)
        setAccessibilityLabel(title)
    }

    func showResult(note text: String?, canApply: Bool) {
        spinner.stopAnimation(nil)
        note.stringValue = text ?? ""
        note.isHidden = text == nil
        buttons.setEnabled(canApply, forSegment: 0)
    }

    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = NSColor.quaternarySystemFill.cgColor
    }

    override var wantsUpdateLayer: Bool { true }

    @objc private func clicked() {
        if buttons.selectedSegment == 0 { onAccept?() } else { onReject?() }
    }
}
