import AppKit
import LuxCore
import SwiftUI

/// Encryption: whether this Mac is verified, the account's devices (verifying one that is not,
/// signing another out), the key backup with the field for the recovery key that opens it, and
/// setting recovery up for an account that has none.
final class EncryptionSettingsController: NSViewController {
    private let model: SettingsModel
    private let session: Session
    private var observation: AnyObject?
    private var securityObservation: AnyObject?
    private var activation: NSObjectProtocol?
    private var isRecovering = false
    /// What the last Unlock said, and whether it failed.
    private var outcome: (text: String, failed: Bool)?
    private lazy var form = NSHostingView.pane(makeForm())

    init(session: Session, model: SettingsModel) {
        self.session = session
        self.model = model
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Encryption")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = form
        observation = model.changes.observe { [weak self] in self?.update() }
        securityObservation = session.security?.changes.observe { [weak self] in self?.update() }
        reloadDevices()
        // back from the account page in the browser: a device may have signed out there.
        activation = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadDevices() }
        }
    }

    isolated deinit {
        if let activation { NotificationCenter.default.removeObserver(activation) }
    }

    private func reloadDevices() {
        Task {
            do { try await session.security?.loadDevices() } catch { report(error, of: "devices") }
        }
    }

    private func update() {
        form.rootView = makeForm()
    }

    private func makeForm() -> EncryptionForm {
        EncryptionForm(
            isVerified: model.isVerified, devices: session.security?.devices ?? [], recovery: model.recovery,
            isRecovering: isRecovering, outcome: outcome,
            actions: .init(
                verify: { [weak self] in self?.verifyDevice() },
                verifyDevice: { [weak self] in self?.verifyOther($0) },
                signOutDevice: { [weak self] in self?.signOut($0) },
                setUpRecovery: { [weak self] in self?.startRecoverySetup() },
                recover: { [weak self] in self?.recover(key: $0) }
            )
        )
    }

    private func verifyDevice() {
        let sheet = VerificationController(model: VerificationModel(session: session)) { [weak self] in
            Task { await self?.model.load() }
        }
        presentAsSheet(sheet)
    }

    private func verifyOther(_ device: OwnDevice) {
        let sheet = VerificationController(model: VerificationModel(session: session, kind: .device(device))) { [weak self] in
            self?.reloadDevices()
        }
        presentAsSheet(sheet)
    }

    /// Signs `device` out: on the server's account page, or here with the account's password.
    private func signOut(_ device: OwnDevice) {
        guard let security = session.security else { return }
        Task {
            do {
                switch try await security.signOutMethod(for: device) {
                case .inBrowser(let url):
                    // the page asks to confirm; the list reloads when Lux is back in front.
                    NSWorkspace.shared.open(url)
                case .withPassword:
                    askPassword(to: device, security: security)
                }
            } catch {
                show(error)
            }
        }
    }

    /// Asks for the account's password to sign `device` out, again after a wrong one.
    private func askPassword(to device: OwnDevice, security: SecurityModel, after failure: (any Error)? = nil) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Sign Out “\(device.title)”?")
        alert.informativeText = failure?.localizedDescription
            ?? String(localized: "It will no longer be able to read your messages. Enter your account's password to sign it out.")
        let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        password.placeholderString = String(localized: "Password")
        alert.accessoryView = password
        let signOut = alert.addButton(withTitle: String(localized: "Sign Out"))
        signOut.hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = password
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let text = password.stringValue
            Task { [weak self] in
                do {
                    try await security.signOut(device, password: text)
                } catch {
                    self?.askPassword(to: device, security: security, after: error)
                }
            }
        }
    }

    private func show(_ error: any Error) {
        guard let window = view.window else { return }
        NSAlert(error: error).beginSheetModal(for: window)
    }

    private func startRecoverySetup() {
        guard let security = session.security else { return }
        presentAsSheet(RecoverySetupController(security: security))
    }

    private func recover(key: String) {
        isRecovering = true
        outcome = nil
        update()
        Task {
            defer {
                isRecovering = false
                update()
            }
            do {
                try await model.recover(key: key)
                outcome = (String(localized: "Unlocked. Encrypted messages appear as their chats load."), false)
            } catch {
                outcome = (error.localizedDescription, true)
            }
        }
    }
}

/// The Encryption pane's form: this Mac, the account's devices, and the key backup.
struct EncryptionForm: View {
    struct Actions {
        var verify: @MainActor () -> Void
        var verifyDevice: @MainActor (OwnDevice) -> Void
        var signOutDevice: @MainActor (OwnDevice) -> Void
        var setUpRecovery: @MainActor () -> Void
        var recover: @MainActor (String) -> Void
    }

    let isVerified: Bool?
    let devices: [OwnDevice]
    let recovery: RecoveryState
    let isRecovering: Bool
    let outcome: (text: String, failed: Bool)?
    let actions: Actions
    @State private var key = ""

    var body: some View {
        Form {
            Section {
                LabeledContent(String(localized: "This Mac")) {
                    HStack {
                        Text(verified)
                        if isVerified == false { Button(String(localized: "Verify This Mac…"), action: actions.verify) }
                    }
                }
            }
            Section(String(localized: "Devices")) {
                if devices.isEmpty { Text(String(localized: "Loading…")).foregroundStyle(.secondary) }
                // verifying another device needs a verified Mac.
                ForEach(devices) { device in row(device, canVerify: isVerified == true) }
            }
            Section {
                LabeledContent(String(localized: "Key backup")) {
                    HStack {
                        Text(recovery.title)
                        // an account without recovery sets it up; one with it opens it here with the key.
                        if recovery == .disabled, isVerified == true {
                            Button(String(localized: "Set Up Recovery…"), action: actions.setUpRecovery)
                        }
                    }
                }
                if recovery != .disabled {
                    TextField(String(localized: "Recovery key"), text: $key, prompt: Text(verbatim: "EsT…"))
                        .font(.body.monospaced())
                        .disabled(recovery == .enabled)
                        .onSubmit(unlock)
                    HStack {
                        if let outcome {
                            Text(outcome.text).foregroundStyle(outcome.failed ? .red : .secondary)
                        }
                        Spacer()
                        if isRecovering { ProgressView().controlSize(.small) }
                        Button(String(localized: "Unlock"), action: unlock)
                            .keyboardShortcut(.defaultAction)
                            .disabled(recovery == .enabled || isRecovering || key.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            } footer: {
                if recovery != .disabled {
                    Text(String(localized: """
                        Encrypted messages from before this device signed in are in your account's key backup. \
                        Enter the recovery key you saved when you set it up (in Lux, Element or another app).
                        """))
                    .formFooter()
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: recovery) { if recovery == .enabled { key = "" } }
    }

    private var verified: String {
        switch isVerified {
        case true?: String(localized: "Verified")
        case false?: String(localized: "Not verified")
        case nil: String(localized: "Checking…")
        }
    }

    private func unlock() {
        guard recovery != .enabled, !isRecovering, !key.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        actions.recover(key)
    }

    /// A device: whether it is verified, its name, and for another device Verify and Sign Out.
    private func row(_ device: OwnDevice, canVerify: Bool) -> some View {
        HStack {
            Image(systemName: device.isVerified ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                .foregroundStyle(device.isVerified ? .green : .orange)
                .accessibilityLabel(device.isVerified ? String(localized: "Verified") : String(localized: "Not verified"))
            Text(device.isThisDevice ? String(localized: "\(device.title) (this Mac)") : device.title)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(device.id)
            Spacer(minLength: 8)
            if !device.isThisDevice {
                if !device.isVerified, canVerify {
                    Button(String(localized: "Verify…")) { actions.verifyDevice(device) }
                }
                Button(String(localized: "Sign Out…")) { actions.signOutDevice(device) }
            }
        }
    }
}
