import AppKit
import LuxCore

/// A verification with another of the account's devices, in a sheet: this Mac from any of them,
/// another device from this Mac, or another device's request, accepted here. Wait for the other
/// device, compare the emojis, answer.
final class VerificationController: NSViewController {
    private let model: VerificationModel
    private let done: () -> Void
    private let symbol = NSImageView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let emojis = NSStackView()
    private lazy var match = NSButton(title: String(localized: "They Match"), target: self, action: #selector(confirm))
    private lazy var noMatch = NSButton(title: String(localized: "They Don't Match"), target: self, action: #selector(deny))
    private lazy var accept = NSButton(title: String(localized: "Accept"), target: self, action: #selector(acceptRequest))
    private lazy var close = NSButton(title: String(localized: "Cancel"), target: self, action: #selector(closeSheet))
    private let buttons = NSStackView()

    init(model: VerificationModel, done: @escaping () -> Void = {}) {
        self.model = model
        self.done = done
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        symbol.symbolConfiguration = .init(pointSize: 40, weight: .regular)
        status.font = .systemFont(ofSize: 15, weight: .semibold)
        status.alignment = .center
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        for label in [status, detail] { label.preferredMaxLayoutWidth = 380 }
        spinner.style = .spinning
        spinner.startAnimation(nil)
        emojis.distribution = .fillEqually
        emojis.spacing = 6
        close.keyEquivalent = "\u{1b}"
        buttons.setViews([close, NSView(), noMatch, match, accept], in: .leading)
        let stack = NSStackView(views: [symbol, spinner, status, detail, emojis, buttons])
        stack.orientation = .vertical
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 20, right: 24)
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
        stack.widthAnchor.constraint(equalToConstant: 460).isActive = true
        view = stack
        model.onStep = { [weak self] step in self?.show(step) }
        show(model.step ?? (isRequest ? .requested : .waiting))
        model.start()
    }

    private var isRequest: Bool {
        if case .request = model.kind { true } else { false }
    }

    /// The other device's name, for the words.
    private var otherName: String? {
        switch model.kind {
        case .thisDevice: nil
        case .device(let device): device.title
        case .request(let device): device?.title
        }
    }

    private func show(_ step: VerificationStep) {
        symbol.isHidden = true
        symbol.contentTintColor = .controlAccentColor
        spinner.isHidden = true
        emojis.isHidden = true
        match.isHidden = true
        noMatch.isHidden = true
        accept.isHidden = true
        match.keyEquivalent = ""
        accept.keyEquivalent = ""
        close.title = String(localized: "Cancel")
        // over: the one button closes, where the sheet's default button is.
        buttons.setViews(step.isFinal ? [NSView(), close] : [close, NSView(), noMatch, match, accept], in: .leading)
        switch step {
        case .requested:
            symbol.image = NSImage(systemSymbolName: "lock.shield", accessibilityDescription: nil)
            symbol.isHidden = false
            status.stringValue = otherName.map { String(localized: "\($0) wants to verify") } ?? String(localized: "Another device wants to verify")
            detail.stringValue = String(localized: "Accept only if you started this on your other device. You will compare emojis on both.")
            accept.isHidden = false
            accept.keyEquivalent = "\r"
            close.title = String(localized: "Decline")
        case .waiting, .accepted:
            spinner.isHidden = false
            if step == .accepted {
                status.stringValue = String(localized: "Connecting…")
            } else if let otherName, !isRequest {
                status.stringValue = String(localized: "Waiting for \(otherName)")
            } else {
                status.stringValue = String(localized: "Waiting for your other device")
            }
            detail.stringValue = switch model.kind {
            case .thisDevice: String(localized: "Open Lux or Element on a device you are signed in on, and accept the request.")
            case .device: String(localized: "Accept the request on that device.")
            case .request: String(localized: "Keep both devices open.")
            }
        case .compare(let list):
            status.stringValue = String(localized: "Do these match?")
            detail.stringValue = String(localized: "Compare them with your other device, in the same order.")
            emojis.setViews(list.map(Self.tile), in: .center)
            emojis.isHidden = false
            match.isHidden = false
            noMatch.isHidden = false
            match.keyEquivalent = "\r"
        case .done:
            symbol.image = NSImage(systemSymbolName: "checkmark.shield.fill", accessibilityDescription: nil)
            symbol.contentTintColor = .systemGreen
            symbol.isHidden = false
            if model.kind == .thisDevice {
                status.stringValue = String(localized: "This Mac is verified")
                detail.stringValue = String(localized: "Your other devices now share their message keys with it.")
            } else {
                status.stringValue = otherName.map { String(localized: "\($0) is verified") } ?? String(localized: "Verified")
                detail.stringValue = String(localized: "Your devices trust each other and share their message keys.")
            }
            close.title = String(localized: "Done")
            close.keyEquivalent = "\r"
            done()
        case .cancelled:
            status.stringValue = String(localized: "Verification stopped")
            detail.stringValue = String(localized: "Nothing was changed. You can start again.")
            close.title = String(localized: "Close")
        case .failed:
            symbol.image = NSImage(systemSymbolName: "xmark.shield", accessibilityDescription: nil)
            symbol.contentTintColor = .systemRed
            symbol.isHidden = false
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
    @objc private func acceptRequest() { model.accept() }

    /// Closes the sheet; a verification still going is cancelled (a request declined).
    @objc private func closeSheet() {
        if model.step?.isFinal != true { model.cancel() }
        dismiss(nil)
    }
}
