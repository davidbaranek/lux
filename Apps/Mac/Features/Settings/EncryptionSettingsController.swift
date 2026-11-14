import AppKit
import LuxCore

/// Encryption: whether this Mac is verified, the account's devices (verifying one that is not),
/// the key backup with the field for the recovery key that opens it, and setting recovery up for
/// an account that has none.
final class EncryptionSettingsController: NSViewController, NSTextFieldDelegate {
    private let model: SettingsModel
    private let session: Session
    private let verified = NSTextField(labelWithString: "")
    private lazy var verify = NSButton(title: String(localized: "Verify This Mac…"), target: self, action: #selector(verifyDevice))
    private var observation: AnyObject?
    private var securityObservation: AnyObject?
    private let devices = NSStackView()
    private let status = NSTextField(labelWithString: "")
    private lazy var setUpRecovery = NSButton(title: String(localized: "Set Up Recovery…"), target: self, action: #selector(startRecoverySetup))
    private let explanation = NSTextField(wrappingLabelWithString: String(localized: """
        Encrypted messages from before this device signed in are in your account's key backup. \
        Enter the recovery key you saved when you set it up (in Lux, Element or another app).
        """))
    private let key = NSTextField()
    private let unlock = NSButton()
    private let progress = NSProgressIndicator()
    private let message = NSTextField(wrappingLabelWithString: "")
    private var keyRows: [NSGridRow] = []

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
        explanation.preferredMaxLayoutWidth = 340
        explanation.textColor = .secondaryLabelColor
        devices.orientation = .vertical
        devices.alignment = .leading
        devices.spacing = 6
        let actions = NSStackView(views: [unlock, progress])
        let verifyRow = NSStackView(views: [verified, verify])
        let recoveryRow = NSStackView(views: [status, setUpRecovery])
        let form = settingsForm([
            [NSTextField(labelWithString: String(localized: "This Mac:")), verifyRow],
            [NSTextField(labelWithString: String(localized: "Devices:")), devices],
            [NSTextField(labelWithString: String(localized: "Key backup:")), recoveryRow],
            [NSGridCell.emptyContentView, explanation],
            [NSTextField(labelWithString: String(localized: "Recovery key:")), key],
            [NSGridCell.emptyContentView, actions],
            [NSGridCell.emptyContentView, message],
        ])
        if let grid = form.subviews.first as? NSGridView {
            grid.row(at: 1).yPlacement = .top
            keyRows = (3...5).map { grid.row(at: $0) }
        }
        view = form
        observation = model.changes.observe { [weak self] in self?.update() }
        securityObservation = session.security?.changes.observe { [weak self] in self?.updateDevices() }
        update()
        updateDevices()
        Task { await session.security?.loadDevices() }
    }

    private func update() {
        verified.stringValue = switch model.isVerified {
        case true?: String(localized: "Verified")
        case false?: String(localized: "Not verified")
        case nil: String(localized: "Checking…")
        }
        verify.isHidden = model.isVerified != false
        status.stringValue = model.recovery.title
        // an account without recovery sets it up; one with it opens it here with the key.
        let disabled = model.recovery == .disabled
        setUpRecovery.isHidden = !disabled || model.isVerified != true
        for row in keyRows { row.isHidden = disabled }
        let open = model.recovery == .enabled
        key.isEnabled = !open
        if open { key.stringValue = "" }
        unlock.isEnabled = !open && !key.stringValue.isEmpty
        updateDevices()
    }

    /// One row per device: its name, whether it is verified, and a button to verify one that is
    /// not (only from a verified Mac).
    private func updateDevices() {
        let canVerify = model.isVerified == true
        let rows = (session.security?.devices ?? []).map { device -> NSView in
            let name = NSTextField(labelWithString: device.isThisDevice ? String(localized: "\(device.title) (this Mac)") : device.title)
            let state = NSImageView(image: NSImage(systemSymbolName: device.isVerified ? "checkmark.shield" : "exclamationmark.shield",
                                                   accessibilityDescription: device.isVerified ? String(localized: "Verified") : String(localized: "Not verified"))
                ?? NSImage())
            state.contentTintColor = device.isVerified ? .systemGreen : .systemOrange
            let row = NSStackView(views: [state, name])
            if !device.isVerified, !device.isThisDevice, canVerify {
                let button = DeviceButton(title: String(localized: "Verify…"), target: self, action: #selector(verifyOther(_:)))
                button.device = device
                button.controlSize = .small
                row.addArrangedSubview(button)
            }
            return row
        }
        devices.setViews(rows.isEmpty ? [NSTextField(labelWithString: String(localized: "Loading…"))] : rows, in: .top)
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

    @objc private func verifyOther(_ sender: DeviceButton) {
        guard let device = sender.device else { return }
        let sheet = VerificationController(model: VerificationModel(session: session, kind: .device(device))) { [weak self] in
            Task { await self?.session.security?.loadDevices() }
        }
        presentAsSheet(sheet)
    }

    @objc private func startRecoverySetup() {
        guard let security = session.security else { return }
        presentAsSheet(RecoverySetupController(security: security))
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

/// A row's Verify button, with the device it verifies.
private final class DeviceButton: NSButton {
    var device: OwnDevice?
}
