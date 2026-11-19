import AppKit
import LuxCore

/// A glass note over the chat's top of a message pinned since the user last saw the chat's pins
/// (on any of their devices). A click goes to it; the close button puts it away. Either way the
/// pins are seen, and the note stays away until another message is pinned. The chat's details
/// list all its pinned messages.
final class NewPinBar: NSView {
    /// Go to the pinned message.
    var onJump: ((PinnedMessage) -> Void)?
    /// The user saw the pin: went to it or closed the note.
    var onSeen: (() -> Void)?
    private var pin: PinnedMessage?
    private let button = NSButton()
    private let close = NSButton()

    init() {
        super.init(frame: .zero)
        button.bezelStyle = .glass
        button.controlSize = .large
        button.image = NSImage.symbol("pin.fill", label: String(localized: "Pinned"))
        button.imagePosition = .imageLeading
        button.alignment = .left
        button.lineBreakMode = .byTruncatingTail
        button.target = self
        button.action = #selector(jump)
        close.bezelStyle = .glass
        close.controlSize = .large
        close.image = NSImage.symbol("xmark", label: String(localized: "Close"))
        close.setAccessibilityLabel(String(localized: "Close"))
        close.toolTip = String(localized: "Close")
        close.target = self
        close.action = #selector(dismiss)
        let row = NSStackView(views: [button, close])
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        isHidden = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Tells of `pin`, the newest the user has not seen, or hides when there is none.
    func show(_ pin: PinnedMessage?) {
        self.pin = pin
        isHidden = pin == nil
        guard let pin else { return }
        let line = pin.text.isEmpty ? pin.senderName : "\(pin.senderName): \(pin.text)"
        let title = NSMutableAttributedString(string: String(localized: "New Pinned Message") + "  ", attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
            .foregroundColor: NSColor.controlAccentColor,
        ])
        title.append(NSAttributedString(string: line, attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]))
        button.attributedTitle = title
        button.setAccessibilityLabel(String(localized: "New pinned message from \(pin.senderName): \(pin.text)"))
    }

    @objc private func jump() {
        guard let pin else { return }
        onJump?(pin)
        dismiss()
    }

    @objc private func dismiss() {
        show(nil)
        onSeen?()
    }
}
