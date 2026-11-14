import AppKit
import LuxCore

/// Encryption: whether this device reads the account's key backup, and the field for the recovery
/// key that opens it.
final class EncryptionSettingsController: NSViewController, NSTextFieldDelegate {
    private let model: SettingsModel
    private let session: Session
    private let verified = NSTextField(labelWithString: "")
    private var observation: AnyObject?
    private let status = NSTextField(labelWithString: "")
    private let key = NSTextField()
    private let unlock = NSButton()
    private let progress = NSProgressIndicator()
    private let message = NSTextField(wrappingLabelWithString: "")

    init(session: Session, model: SettingsModel) {
        self.session = session
        self.model = model
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Encryption")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        key.placeholderString = "EsT…"
        key.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        key.delegate = self
        key.setAccessibilityLabel(String(localized: "Recovery key"))
        key.widthAnchor.constraint(equalToConstant: 340).isActive = true
        unlock.title = String(localized: "Unlock")
        unlock.bezelStyle = .push
        unlock.keyEquivalent = "\r"
        unlock.target = self
        unlock.action = #selector(recover)
        unlock.isEnabled = false
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        message.preferredMaxLayoutWidth = 340
        message.textColor = .secondaryLabelColor
        let explanation = NSTextField(wrappingLabelWithString: String(localized: """
            Encrypted messages from before this device signed in are in your account's key backup. \
            Enter the recovery key you saved when you set it up (in Lux, Element or another app).
            """))
        explanation.preferredMaxLayoutWidth = 340
        explanation.textColor = .secondaryLabelColor
        let actions = NSStackView(views: [unlock, progress])
        let verify = NSButton(title: String(localized: "Verify This Device…"), target: self, action: #selector(verifyDevice))
        let verifyRow = NSStackView(views: [verified, verify])
        view = settingsForm([
            [NSTextField(labelWithString: String(localized: "This Mac:")), verifyRow],
            [NSTextField(labelWithString: String(localized: "Key backup:")), status],
            [NSGridCell.emptyContentView, explanation],
            [NSTextField(labelWithString: String(localized: "Recovery key:")), key],
            [NSGridCell.emptyContentView, actions],
            [NSGridCell.emptyContentView, message],
        ])
        observation = model.changes.observe { [weak self] in self?.update() }
        update()
    }

    private func update() {
        verified.stringValue = switch model.isVerified {
        case true?: String(localized: "Verified")
        case false?: String(localized: "Not verified")
        case nil: String(localized: "Checking…")
        }
        status.stringValue = model.recovery.title
        let open = model.recovery == .enabled
        key.isEnabled = !open
        if open { key.stringValue = "" }
        unlock.isEnabled = !open && !key.stringValue.isEmpty
    }

    func controlTextDidChange(_ notification: Notification) {
        unlock.isEnabled = !key.stringValue.trimmingCharacters(in: .whitespaces).isEmpty && model.recovery != .enabled
    }

    @objc private func verifyDevice() {
        let sheet = VerificationController(model: VerificationModel(session: session)) { [weak self] in
            Task { await self?.model.load() }
        }
        presentAsSheet(sheet)
    }

    @objc private func recover() {
        unlock.isEnabled = false
        progress.startAnimation(nil)
        message.stringValue = ""
        let text = key.stringValue
        Task {
            defer {
                progress.stopAnimation(nil)
                update()
            }
            do {
                try await model.recover(key: text)
                message.textColor = .secondaryLabelColor
                message.stringValue = String(localized: "Unlocked. Encrypted messages appear as their chats load.")
            } catch {
                message.textColor = .systemRed
                message.stringValue = error.localizedDescription
            }
        }
    }
}
