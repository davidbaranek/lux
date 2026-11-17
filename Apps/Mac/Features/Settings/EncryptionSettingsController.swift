import AppKit
import LuxCore

/// Encryption: whether this Mac is verified, the account's devices (verifying one that is not,
/// signing another out), the key backup with the field for the recovery key that opens it, and
/// setting recovery up for an account that has none.
final class EncryptionSettingsController: NSViewController, NSTextFieldDelegate {
    private let model: SettingsModel
    private let session: Session
    private let verified = NSTextField(labelWithString: "")
    private lazy var verify = NSButton(title: String(localized: "Verify This Mac…"), target: self, action: #selector(verifyDevice))
    private var observation: AnyObject?
    private var securityObservation: AnyObject?
    private lazy var devices = DeviceList(
        verify: { [weak self] device in self?.verifyOther(device) },
        signOut: { [weak self] device in self?.signOut(device) }
    )
    private var activation: NSObjectProtocol?
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

    /// The account's devices; verifying one needs a verified Mac.
    private func updateDevices() {
        devices.show(session.security?.devices ?? [], canVerify: model.isVerified == true)
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

/// The account's devices, in a list of its own height that scrolls: an account can have dozens.
/// Each other device can be signed out; an unverified one verified.
private final class DeviceList: NSScrollView, NSTableViewDelegate {
    private enum Item: Hashable {
        /// Before the first answer.
        case loading
        case device(String)
    }

    private let table = NSTableView()
    private var dataSource: NSTableViewDiffableDataSource<Int, Item>!
    private var rows: [OwnDevice] = []
    private var byId: [String: OwnDevice] = [:]
    private var canVerify = false
    private let verify: (OwnDevice) -> Void
    private let signOut: (OwnDevice) -> Void

    init(verify: @escaping (OwnDevice) -> Void, signOut: @escaping (OwnDevice) -> Void) {
        self.verify = verify
        self.signOut = signOut
        super.init(frame: .zero)
        let column = NSTableColumn(identifier: .init("device"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.headerView = nil
        table.style = .plain
        table.rowHeight = 30
        table.selectionHighlightStyle = .none
        table.usesAlternatingRowBackgroundColors = true
        table.delegate = self
        table.setAccessibilityLabel(String(localized: "Devices"))
        dataSource = NSTableViewDiffableDataSource(tableView: table) { [weak self] _, _, _, item in
            guard case .device(let id) = item, let self, let device = byId[id] else {
                return Self.cell([NSTextField(labelWithString: String(localized: "Loading…"))])
            }
            return view(for: device)
        }
        // until the first answer, one row says it is loading.
        var loading = NSDiffableDataSourceSnapshot<Int, Item>()
        loading.appendSections([0])
        loading.appendItems([.loading])
        dataSource.apply(loading, animatingDifferences: false)
        documentView = table
        hasVerticalScroller = true
        autohidesScrollers = true
        borderType = .bezelBorder
        widthAnchor.constraint(equalToConstant: 360).isActive = true
        // about seven rows; the rest scroll.
        heightAnchor.constraint(equalToConstant: 216).isActive = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// The devices as they are now: a device that came or went is a row inserted or removed; only a
    /// device whose state changed (or every one, when verifying becomes possible) is drawn again.
    func show(_ devices: [OwnDevice], canVerify: Bool) {
        guard devices != rows || canVerify != self.canVerify else { return }
        let old = byId, verifyChanged = canVerify != self.canVerify
        rows = devices
        byId = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        self.canVerify = canVerify
        var snapshot = NSDiffableDataSourceSnapshot<Int, Item>()
        snapshot.appendSections([0])
        snapshot.appendItems(devices.isEmpty ? [.loading] : devices.map { .device($0.id) })
        let changed = byId.filter { id, device in old[id].map { verifyChanged || $0 != device } ?? false }.map { Item.device($0.key) }
        snapshot.reloadItems(changed)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func view(for device: OwnDevice) -> NSView {
        let state = NSImageView(image: NSImage(
            systemSymbolName: device.isVerified ? "checkmark.shield" : "exclamationmark.shield",
            accessibilityDescription: device.isVerified ? String(localized: "Verified") : String(localized: "Not verified")
        ) ?? NSImage())
        state.contentTintColor = device.isVerified ? .systemGreen : .systemOrange
        let name = NSTextField(labelWithString: device.isThisDevice ? String(localized: "\(device.title) (this Mac)") : device.title)
        name.lineBreakMode = .byTruncatingTail
        name.toolTip = device.id
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var views: [NSView] = [state, name, NSView()]
        if !device.isThisDevice {
            if !device.isVerified, canVerify {
                views.append(Self.button(String(localized: "Verify…")) { [weak self] in self?.verify(device) })
            }
            views.append(Self.button(String(localized: "Sign Out…")) { [weak self] in self?.signOut(device) })
        }
        return Self.cell(views)
    }

    private static func cell(_ views: [NSView]) -> NSView {
        let row = NSStackView(views: views)
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        return row
    }

    private static func button(_ title: String, action: @escaping () -> Void) -> NSButton {
        let button = ActionButton(title: title, perform: action)
        button.controlSize = .small
        return button
    }
}
