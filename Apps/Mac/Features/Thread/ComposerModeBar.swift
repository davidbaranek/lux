import AppKit

/// "Replying to Anna — hi there" / "Editing — old text" above the composer's field, with a
/// button that cancels (Escape does too).
final class ComposerModeBar: NSStackView {
    var onCancel: (() -> Void)?
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        icon.contentTintColor = .controlAccentColor
        title.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        title.textColor = .controlAccentColor
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let cancel = NSButton(image: NSImage.symbol("xmark.circle.fill", label: String(localized: "Cancel")),
                              target: self, action: #selector(cancelled))
        cancel.isBordered = false
        cancel.contentTintColor = .tertiaryLabelColor
        let labels = NSStackView(views: [title, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 0
        setViews([icon, labels, NSView(), cancel], in: .leading)
        spacing = 8
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(symbol: String, title: String, detail: String) {
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        self.title.stringValue = title
        self.detail.stringValue = detail
        setAccessibilityLabel("\(title), \(detail)")
    }

    @objc private func cancelled() { onCancel?() }
}
