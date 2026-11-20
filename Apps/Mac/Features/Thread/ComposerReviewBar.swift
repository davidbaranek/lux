import AppKit

/// An AI action above the composer's field: working (a spinner), then its result's ✓ and ✕.
final class ComposerReviewBar: NSStackView {
    var onAccept: (() -> Void)?
    var onReject: (() -> Void)?
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let note = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private lazy var accept = NSButton(image: NSImage.symbol("checkmark.circle.fill", label: String(localized: "Apply")),
                                       target: self, action: #selector(accepted))
    private lazy var reject = NSButton(image: NSImage.symbol("xmark.circle.fill", label: String(localized: "Cancel")),
                                       target: self, action: #selector(rejected))

    init() {
        super.init(frame: .zero)
        icon.contentTintColor = .controlAccentColor
        title.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        title.textColor = .controlAccentColor
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        for button in [accept, reject] {
            button.isBordered = false
        }
        accept.contentTintColor = .systemGreen
        reject.contentTintColor = .tertiaryLabelColor
        let labels = NSStackView(views: [title, note])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 0
        setViews([icon, labels, NSView(), spinner, accept, reject], in: .leading)
        spacing = 8
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

    @objc private func accepted() { onAccept?() }
    @objc private func rejected() { onReject?() }
}
