import AppKit
import LuxCore

/// The networks the account's server bridges, one row each: its logo, whether the account is
/// signed in there, and a button to sign in or out. A tab of Settings; after signing in, the
/// welcome sheet, where the user ticks the networks to bring and signs in to each in turn. A
/// server that offers none, or a bridge that does not answer, says so, with the guide for its
/// admin.
final class NetworksController: NSViewController {
    enum Mode { case settings, welcome }

    private let model: NetworksModel
    private let mode: Mode
    private var observation: AnyObject?
    private let rows = NSStackView()
    private var picked: Set<NetworkOffer> = []
    private var queue: [NetworkOffer] = []
    private lazy var connect = NSButton(title: "", target: self, action: #selector(connectPicked))
    /// The welcome is done (closed, or every sign-in went).
    var onDone: (() -> Void)?

    init(model: NetworksModel, mode: Mode) {
        self.model = model
        self.mode = mode
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Networks")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 14
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 28, bottom: 24, right: 28)
        if mode == .welcome {
            let heading = NSTextField(labelWithString: String(localized: "Your Networks"))
            heading.font = .systemFont(ofSize: 22, weight: .bold)
            stack.addArrangedSubview(heading)
        }
        let intro = NSTextField(wrappingLabelWithString: mode == .welcome
            ? String(localized: "Pick the networks whose chats Lux should show. You sign in to each on its own website or with its app; your server keeps the connection.")
            : String(localized: "Your server's bridges connect these networks. Signing out here disconnects the network from your account, on every device."))
        intro.textColor = .secondaryLabelColor
        intro.preferredMaxLayoutWidth = 464
        stack.addArrangedSubview(intro)
        stack.addArrangedSubview(rows)
        if mode == .welcome {
            connect.keyEquivalent = "\r"
            connect.bezelStyle = .push
            let later = NSButton(title: String(localized: "Not Now"), target: self, action: #selector(close))
            later.keyEquivalent = "\u{1b}"
            let buttons = NSStackView(views: [later, connect])
            stack.addArrangedSubview(buttons)
            buttons.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -28).isActive = true
        }
        stack.widthAnchor.constraint(equalToConstant: 520).isActive = true
        view = stack
        observation = model.changes.observe { [weak self] in self?.update() }
        update()
        Task { await model.load() }
    }

    private func update() {
        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        switch model.offers {
        case .loading:
            rows.addArrangedSubview(message(String(localized: "Asking your server…"), detail: nil, symbol: nil))
        case .notSet(let server):
            rows.addArrangedSubview(message(
                String(localized: "\(server) offers no networks to Lux"),
                detail: String(localized: "Its server may bridge WhatsApp, Messenger and others, but does not tell Lux where. Its admin can set that up; until then, you can still sign in to a bridge by writing to its bot."),
                symbol: "network.slash"))
            rows.addArrangedSubview(guideButton())
        case .failed(let failure):
            rows.addArrangedSubview(message(String(localized: "Your server could not be asked"), detail: failure.localizedDescription,
                                            symbol: "exclamationmark.triangle"))
            rows.addArrangedSubview(NSButton(title: String(localized: "Try Again"), target: self, action: #selector(reload)))
        case .offered(let offers):
            for offer in offers { rows.addArrangedSubview(row(offer)) }
        }
        connect.title = picked.isEmpty ? String(localized: "Connect") : String(localized: "Connect \(picked.count) Networks")
        connect.isEnabled = !picked.isEmpty
        connect.isHidden = model.offered.isEmpty
    }

    private func row(_ offer: NetworkOffer) -> NSView {
        let logo = NSImageView(image: NetworkImage.image(offer.network))
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.widthAnchor.constraint(equalToConstant: 32).isActive = true
        logo.heightAnchor.constraint(equalToConstant: 32).isActive = true
        let name = NSTextField(labelWithString: offer.name)
        name.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let status = NSTextField(wrappingLabelWithString: "")
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.preferredMaxLayoutWidth = 300
        let texts = NSStackView(views: [name, status])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 2
        var trailing: NSView?
        switch model.statuses[offer] ?? .loading {
        case .loading:
            status.stringValue = String(localized: "Checking…")
        case .account(let account):
            if let login = account.logins.first {
                status.stringValue = login.state == .connected
                    ? String(localized: "Connected as \(login.name)") : "\(login.name) · \(login.state.title)"
                if login.state.needsSignIn { status.textColor = .systemOrange }
            } else {
                status.stringValue = String(localized: "Not connected")
            }
            if mode == .welcome, account.logins.isEmpty {
                let tick = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggled(_:)))
                tick.state = picked.contains(offer) ? .on : .off
                tick.identifier = NSUserInterfaceItemIdentifier(offer.network)
                trailing = tick
            } else if account.logins.isEmpty || account.needsSignIn {
                trailing = action(String(localized: "Connect…"), offer) { [weak self] in self?.signIn(to: offer) }
            } else {
                trailing = action(String(localized: "Sign Out…"), offer) { [weak self] in
                    if let login = account.logins.first { self?.confirmLogOut(offer, login: login) }
                }
            }
        case .failed(let failure):
            status.stringValue = failure.localizedDescription
            status.textColor = .systemRed
            trailing = action(String(localized: "Retry"), offer) { [weak self] in Task { await self?.model.refresh(offer) } }
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [logo, texts, spacer] + [trailing].compactMap { $0 })
        row.spacing = 12
        row.widthAnchor.constraint(equalToConstant: 464).isActive = true
        return row
    }

    private func action(_ title: String, _ offer: NetworkOffer, _ perform: @escaping () -> Void) -> NSButton {
        let button = ActionButton(title: title, perform: perform)
        button.setAccessibilityLabel("\(title) \(offer.name)")
        return button
    }

    private func message(_ title: String, detail: String?, symbol: String?) -> NSView {
        let heading = NSTextField(wrappingLabelWithString: title)
        heading.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        heading.preferredMaxLayoutWidth = 420
        let texts = NSStackView(views: [heading])
        texts.orientation = .vertical
        texts.alignment = .leading
        if let detail {
            let body = NSTextField(wrappingLabelWithString: detail)
            body.textColor = .secondaryLabelColor
            body.preferredMaxLayoutWidth = 420
            texts.addArrangedSubview(body)
        }
        guard let symbol else { return texts }
        let image = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        image.symbolConfiguration = .init(pointSize: 22, weight: .regular)
        image.contentTintColor = .secondaryLabelColor
        let row = NSStackView(views: [image, texts])
        row.alignment = .top
        row.spacing = 12
        return row
    }

    private func guideButton() -> NSButton {
        let button = ActionButton(title: String(localized: "How a Server Offers Networks")) {
            NSWorkspace.shared.open(BridgeSetup.guide)
        }
        button.bezelStyle = .inline
        return button
    }

    @objc private func reload() { Task { await model.load() } }

    @objc private func toggled(_ sender: NSButton) {
        guard let offer = model.offered.first(where: { $0.network == sender.identifier?.rawValue }) else { return }
        if sender.state == .on { picked.insert(offer) } else { picked.remove(offer) }
        update()
    }

    @objc private func close() {
        onDone?()
    }

    @objc private func connectPicked() {
        queue = model.offered.filter(picked.contains)
        picked = []
        update()
        signInNext()
    }

    private func signInNext() {
        guard !queue.isEmpty else {
            if mode == .welcome, !model.hasNoLogins { onDone?() }
            return
        }
        signIn(to: queue.removeFirst()) { [weak self] in self?.signInNext() }
    }

    private func signIn(to offer: NetworkOffer, then next: (() -> Void)? = nil) {
        guard let window = view.window else { return }
        NetworkSignInController.present(model.signIn(to: offer), over: window) { next?() }
    }

    private func confirmLogOut(_ offer: NetworkOffer, login: NetworkAccount.Login) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Sign out of \(offer.name)?")
        alert.informativeText = String(localized: "Its chats stop updating on every device. Their history stays.")
        alert.addButton(withTitle: String(localized: "Sign Out"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            Task {
                do { try await self.model.logOut(of: offer, login: login.id) } catch {
                    let failed = NSAlert()
                    failed.messageText = error.localizedDescription
                    failed.beginSheetModal(for: window, completionHandler: nil)
                }
            }
        }
    }
}

/// A push button that runs a closure.
final class ActionButton: NSButton {
    private let perform: () -> Void

    init(title: String, perform: @escaping () -> Void) {
        self.perform = perform
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .push
        target = self
        action = #selector(clicked)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    @objc private func clicked() { perform() }
}
