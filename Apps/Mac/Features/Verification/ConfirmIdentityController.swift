import AppKit
import LuxCore

/// After signing in, while this Mac is not verified: prove it is the account's, with another of
/// its devices (comparing emojis) or with the recovery key. A sheet; the next step takes its place.
final class ConfirmIdentityController: NSViewController {
    private let session: Session
    private let withRecoveryKey: Bool
    private var observation: AnyObject?

    init(session: Session, withRecoveryKey: Bool) {
        self.session = session
        self.withRecoveryKey = withRecoveryKey
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let symbol = NSImageView(image: NSImage(systemSymbolName: "lock.shield", accessibilityDescription: nil) ?? NSImage())
        symbol.symbolConfiguration = .init(pointSize: 44, weight: .regular)
        symbol.contentTintColor = .controlAccentColor
        let heading = NSTextField(labelWithString: String(localized: "Verify this Mac"))
        heading.font = .systemFont(ofSize: 17, weight: .semibold)
        let explanation = NSTextField(wrappingLabelWithString: withRecoveryKey
            ? String(localized: "Your encrypted messages stay locked on this Mac until you verify it, with another device you are signed in on or with your recovery key.")
            : String(localized: "Your encrypted messages stay locked on this Mac until you verify it with another device you are signed in on."))
        explanation.alignment = .center
        explanation.textColor = .secondaryLabelColor
        explanation.preferredMaxLayoutWidth = 380
        let later = NSButton(title: String(localized: "Not Now"), target: self, action: #selector(notNow))
        later.keyEquivalent = "\u{1b}"
        let recoveryKey = NSButton(title: String(localized: "Enter Recovery Key…"), target: self, action: #selector(enterRecoveryKey))
        recoveryKey.isHidden = !withRecoveryKey
        let otherDevice = NSButton(title: String(localized: "Use Another Device"), target: self, action: #selector(useAnotherDevice))
        otherDevice.keyEquivalent = "\r"
        let buttons = NSStackView(views: [later, NSView(), recoveryKey, otherDevice])
        let stack = NSStackView(views: [symbol, heading, explanation, buttons])
        stack.orientation = .vertical
        stack.spacing = 14
        stack.setCustomSpacing(24, after: explanation)
        stack.edgeInsets = NSEdgeInsets(top: 28, left: 24, bottom: 20, right: 24)
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
        stack.widthAnchor.constraint(equalToConstant: 460).isActive = true
        view = stack
        // verified meanwhile (another device's request): nothing left to do.
        observation = session.security?.changes.observe { [weak self] in
            guard let self, let setup = session.security?.setup, setup == .ready || setup == .setUpRecovery else { return }
            if presentingViewController != nil { dismiss(nil) }
        }
    }

    @objc private func notNow() { dismiss(nil) }

    @objc private func useAnotherDevice() {
        replace(with: VerificationController(model: VerificationModel(session: session, kind: .thisDevice)))
    }

    @objc private func enterRecoveryKey() {
        replace(with: RecoveryKeyController(model: SettingsModel(session: session)))
    }

    /// The next step in this sheet's place.
    private func replace(with next: NSViewController) {
        guard let presenting = presentingViewController else { return }
        observation = nil
        dismiss(nil)
        presenting.presentAsSheet(next)
    }
}

/// The recovery key, in a sheet: it opens the key backup and verifies this Mac.
final class RecoveryKeyController: NSViewController, NSTextFieldDelegate {
    private let model: SettingsModel
    private let key = NSTextField()
    private let message = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private lazy var unlock = NSButton(title: String(localized: "Unlock"), target: self, action: #selector(recover))

    init(model: SettingsModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let heading = NSTextField(labelWithString: String(localized: "Enter your recovery key"))
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        let explanation = NSTextField(wrappingLabelWithString: String(localized: "The key you saved when you set up recovery, in Lux, Element or another app."))
        explanation.textColor = .secondaryLabelColor
        explanation.preferredMaxLayoutWidth = 400
        key.placeholderString = "EsT…"
        key.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        key.delegate = self
        key.setAccessibilityLabel(String(localized: "Recovery key"))
        message.preferredMaxLayoutWidth = 400
        message.textColor = .secondaryLabelColor
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        unlock.keyEquivalent = "\r"
        unlock.isEnabled = false
        let cancel = NSButton(title: String(localized: "Cancel"), target: self, action: #selector(closeSheet))
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [progress, NSView(), cancel, unlock])
        let stack = NSStackView(views: [heading, explanation, key, message, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 20, right: 24)
        for row in [key, buttons] { row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true }
        stack.widthAnchor.constraint(equalToConstant: 460).isActive = true
        view = stack
    }

    func controlTextDidChange(_ notification: Notification) {
        unlock.isEnabled = !key.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
    }

    @objc private func recover() {
        unlock.isEnabled = false
        progress.startAnimation(nil)
        message.stringValue = ""
        let text = key.stringValue
        Task {
            defer { progress.stopAnimation(nil) }
            do {
                try await model.recover(key: text)
                dismiss(nil)
            } catch {
                message.textColor = .systemRed
                message.stringValue = error.localizedDescription
                unlock.isEnabled = true
            }
        }
    }

    @objc private func closeSheet() { dismiss(nil) }
}
