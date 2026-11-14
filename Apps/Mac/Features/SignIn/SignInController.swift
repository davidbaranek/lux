import AppKit
import LuxCore

/// The sign-in form: the server (Lux's own, or any other), then a user name and password when the
/// server allows them, and the server's own page in a browser sheet when it offers one. What shows
/// follows what the server says it allows. The iPhone's form, on the Mac.
final class SignInController: NSViewController, NSTextFieldDelegate {
    private let model: SignInModel
    private let signedIn: () -> Void
    private let server = NSTextField()
    private let user = NSTextField()
    private let password = NSSecureTextField()
    private let serverNote = NSTextField(labelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private lazy var signIn = NSButton(title: String(localized: "Sign In"), target: self, action: #selector(signInWithPassword))
    private lazy var browser = NSButton(title: String(localized: "Sign In on the Server's Page…"), target: self, action: #selector(signInInBrowser))
    private lazy var credentials = NSStackView(views: [user, password])

    init(session: Session, signedIn: @escaping () -> Void) {
        model = SignInModel(session: session)
        self.signedIn = signedIn
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let title = NSTextField(labelWithString: "Lux")
        title.font = .systemFont(ofSize: 34, weight: .bold)
        for (field, placeholder) in [(server, String(localized: "Server")), (user, String(localized: "User name")),
                                     (password, String(localized: "Password"))] as [(NSTextField, String)] {
            field.placeholderString = placeholder
            field.controlSize = .large
            field.bezelStyle = .roundedBezel
            field.delegate = self
        }
        server.stringValue = model.homeserver
        user.contentType = .username
        password.contentType = .password
        serverNote.textColor = .secondaryLabelColor
        serverNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .systemRed
        status.alignment = .center
        for button in [signIn, browser] {
            button.bezelStyle = .glass
            button.controlSize = .extraLarge
        }
        browser.image = NSImage(systemSymbolName: "safari", accessibilityDescription: nil)
        browser.imagePosition = .imageLeading
        credentials.orientation = .vertical
        credentials.spacing = 8
        // the app's icon over its name.
        let logo = NSImageView(image: NSImage(named: "LuxLogo") ?? NSImage())
        logo.wantsLayer = true
        logo.layer?.cornerRadius = 18
        logo.layer?.cornerCurve = .continuous
        logo.layer?.masksToBounds = true
        logo.imageScaling = .scaleProportionallyUpOrDown
        NSLayoutConstraint.activate([logo.widthAnchor.constraint(equalToConstant: 80), logo.heightAnchor.constraint(equalToConstant: 80)])
        let form = NSStackView(views: [logo, title, server, serverNote, credentials, signIn, browser, status])
        form.orientation = .vertical
        form.alignment = .centerX
        form.spacing = 10
        form.setCustomSpacing(12, after: logo)
        form.setCustomSpacing(28, after: title)
        form.setCustomSpacing(16, after: serverNote)
        form.setCustomSpacing(16, after: credentials)
        for view in [server, credentials, user, password, signIn, browser, status] as [NSView] {
            view.widthAnchor.constraint(equalToConstant: 300).isActive = true
        }
        let container = NSView()
        form.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(form)
        NSLayoutConstraint.activate([
            form.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            form.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 480),
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 420),
        ])
        view = container
        model.onChange = { [weak self] in self?.update() }
        model.start()
        update()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(credentials.isHidden ? server : user)
    }

    func controlTextDidChange(_ notification: Notification) {
        if (notification.object as? NSTextField) === server { model.setHomeserver(server.stringValue) }
    }

    /// Return in the password signs in.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)), control === password else { return false }
        signInWithPassword()
        return true
    }

    /// What the server allows decides what shows: the password fields, the browser button, both.
    private func update() {
        let methods = model.methods
        serverNote.stringValue = switch model.state {
        case .checking: ""
        case .unreachable: String(localized: "No Matrix server answers there.")
        case .ready(let methods) where !methods.password && !methods.browser: String(localized: "This server does not allow signing in from apps.")
        case .ready: ""
        }
        let byPassword = methods.password
        // the fields fade and slide in and out as the server's answer comes (not on the first draw).
        let shown: [(NSView, Bool)] = [(serverNote, !serverNote.stringValue.isEmpty), (credentials, byPassword), (signIn, byPassword),
                                       (browser, methods.browser)]
        let animated = view.window != nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? 0.25 : 0
            context.allowsImplicitAnimation = animated
            for (view, visible) in shown where view.isHidden == visible {
                view.isHidden = !visible
                view.animator().alphaValue = visible ? 1 : 0
            }
            view.layoutSubtreeIfNeeded()
        }
        // Return goes to the main way in: the password, else the server's page.
        signIn.keyEquivalent = byPassword ? "\r" : ""
        browser.keyEquivalent = byPassword ? "" : "\r"
        for control in [signIn, browser, server, user, password] as [NSControl] { control.isEnabled = !model.isSigningIn }
    }

    @objc private func signInWithPassword() {
        guard !user.stringValue.isEmpty, !password.stringValue.isEmpty else {
            status.stringValue = String(localized: "Enter your user name and password.")
            return
        }
        status.stringValue = ""
        Task {
            do {
                try await model.signIn(user: user.stringValue, password: password.stringValue)
                signedIn()
            } catch {
                status.stringValue = error.localizedDescription
            }
        }
    }

    @objc private func signInInBrowser() {
        guard let window = view.window else { return }
        status.stringValue = ""
        Task {
            do {
                try await model.signInInBrowser(presentingFrom: window)
                signedIn()
            } catch is CancellationError {
            } catch {
                status.stringValue = error.localizedDescription
            }
        }
    }
}
