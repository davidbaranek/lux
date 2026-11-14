import AppKit
import LuxCore

/// Verify this device from another one, in a sheet: wait for it to accept, compare the emojis.
final class VerificationController: NSViewController {
    private let model: VerificationModel
    private let done: () -> Void
    private let status = NSTextField(wrappingLabelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let emojis = NSStackView()
    private lazy var match = NSButton(title: String(localized: "They Match"), target: self, action: #selector(confirm))
    private lazy var noMatch = NSButton(title: String(localized: "They Don't Match"), target: self, action: #selector(deny))
    private lazy var close = NSButton(title: String(localized: "Cancel"), target: self, action: #selector(closeSheet))

    init(model: VerificationModel, done: @escaping () -> Void) {
        self.model = model
        self.done = done
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        status.font = .systemFont(ofSize: 15, weight: .semibold)
        status.alignment = .center
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        for label in [status, detail] { label.preferredMaxLayoutWidth = 380 }
        spinner.style = .spinning
        spinner.startAnimation(nil)
        emojis.distribution = .fillEqually
        emojis.spacing = 6
        match.keyEquivalent = "\r"
        close.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [close, NSView(), noMatch, match])
        let stack = NSStackView(views: [spinner, status, detail, emojis, buttons])
        stack.orientation = .vertical
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 20, right: 24)
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
        stack.widthAnchor.constraint(equalToConstant: 460).isActive = true
        view = stack
        model.onStep = { [weak self] step in self?.show(step) }
        show(.waiting)
        model.start()
    }

    private func show(_ step: VerificationStep) {
        spinner.isHidden = true
        emojis.isHidden = true
        match.isHidden = true
        noMatch.isHidden = true
        close.title = String(localized: "Cancel")
        switch step {
        case .waiting, .accepted:
            spinner.isHidden = false
            status.stringValue = step == .waiting ? String(localized: "Waiting for your other device") : String(localized: "Connecting…")
            detail.stringValue = String(localized: "Open Lux or Element on a device you are signed in on, and accept the request.")
        case .compare(let list):
            status.stringValue = String(localized: "Do these match?")
            detail.stringValue = String(localized: "Compare them with your other device, in the same order.")
            emojis.setViews(list.map(Self.tile), in: .center)
            emojis.isHidden = false
            match.isHidden = false
            noMatch.isHidden = false
        case .done:
            status.stringValue = String(localized: "This device is verified")
            detail.stringValue = String(localized: "Your other devices now share their message keys with it.")
            close.title = String(localized: "Done")
            done()
        case .cancelled:
            status.stringValue = String(localized: "Verification stopped")
            detail.stringValue = String(localized: "Nothing was changed. You can start again.")
            close.title = String(localized: "Close")
        case .failed:
            status.stringValue = String(localized: "Verification failed")
            detail.stringValue = String(localized: "Make sure both devices are online, then try again.")
            close.title = String(localized: "Close")
        }
    }

    private static func tile(_ emoji: VerificationEmoji) -> NSView {
        let symbol = NSTextField(labelWithString: emoji.symbol)
        symbol.font = .systemFont(ofSize: 30)
        let name = NSTextField(labelWithString: emoji.name)
        name.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        name.textColor = .secondaryLabelColor
        let tile = NSStackView(views: [symbol, name])
        tile.orientation = .vertical
        tile.spacing = 2
        tile.setAccessibilityElement(true)
        tile.setAccessibilityLabel(emoji.name)
        return tile
    }

    @objc private func confirm() { model.confirm() }
    @objc private func deny() { model.deny() }

    @objc private func closeSheet() {
        if model.step != .done { model.cancel() }
        dismiss(nil)
    }
}
