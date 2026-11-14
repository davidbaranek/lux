import LuxCore
import UIKit

/// The sign-in form: the server (Lux's own, or any other), then a user name and password when the
/// server allows them, and the server's own page in a browser sheet (passkeys, two-factor,
/// sign-up) when it offers one. What shows follows what the server says it allows.
final class SignInViewController: UIViewController, UITextFieldDelegate {
    private let model: SignInModel
    private let signedIn: () -> Void
    private let server = FilledTextField(placeholder: String(localized: "Server"), look: .text(symbol: "server.rack"))
    private let user = FilledTextField(placeholder: String(localized: "User name"), look: .text(symbol: "person"))
    private let password = FilledTextField(placeholder: String(localized: "Password"), look: .text(symbol: "lock"))
    private let credentials = UIStackView()
    private let serverNote = UILabel()
    private let status = UILabel()
    private lazy var signIn = UIButton(configuration: .prominentGlass(), primaryAction: UIAction { [weak self] _ in self?.signInWithPassword() })
    private lazy var browser = UIButton(configuration: .glass(), primaryAction: UIAction { [weak self] _ in self?.signInInBrowser() })

    init(session: Session, signedIn: @escaping () -> Void) {
        model = SignInModel(session: session)
        self.signedIn = signedIn
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let title = UILabel()
        title.text = "Lux"
        title.font = .preferredFont(forTextStyle: .largeTitle).bold
        title.adjustsFontForContentSizeCategory = true
        title.textAlignment = .center

        server.text = model.homeserver
        server.keyboardType = .URL
        server.textContentType = .URL
        server.clearButtonMode = .whileEditing
        server.returnKeyType = .next
        server.addAction(UIAction { [weak self] _ in self?.model.setHomeserver(self?.server.text ?? "") }, for: .editingChanged)
        user.textContentType = .username
        user.returnKeyType = .next
        password.textContentType = .password
        password.isSecureTextEntry = true
        password.returnKeyType = .go
        for field in [server, user, password] { field.delegate = self }
        serverNote.font = .preferredFont(forTextStyle: .footnote)
        serverNote.textColor = .secondaryLabel
        serverNote.adjustsFontForContentSizeCategory = true
        serverNote.numberOfLines = 0
        status.font = .preferredFont(forTextStyle: .footnote)
        status.adjustsFontForContentSizeCategory = true
        status.textColor = .systemRed
        status.numberOfLines = 0
        status.textAlignment = .center

        credentials.addArrangedSubview(user)
        credentials.addArrangedSubview(password)
        credentials.axis = .vertical
        credentials.spacing = 10
        let form = UIStackView(arrangedSubviews: [server, serverNote, credentials, signIn, browser, status])
        form.axis = .vertical
        form.spacing = 10
        form.setCustomSpacing(24, after: serverNote)
        form.setCustomSpacing(18, after: credentials)
        // the app's icon over its name, as the home screen shows it.
        let logo = UIImageView(image: UIImage(named: "LuxLogo"))
        logo.contentMode = .scaleAspectFit
        logo.layer.cornerRadius = 22
        logo.layer.cornerCurve = .continuous
        logo.clipsToBounds = true
        logo.isAccessibilityElement = false
        let brand = UIStackView(arrangedSubviews: [logo, title])
        brand.axis = .vertical
        brand.alignment = .center
        brand.spacing = 12
        NSLayoutConstraint.activate([logo.widthAnchor.constraint(equalToConstant: 96), logo.heightAnchor.constraint(equalToConstant: 96)])
        let stack = UIStackView(arrangedSubviews: [brand, form])
        stack.axis = .vertical
        stack.spacing = 32
        stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = UIScrollView()
        scroll.keyboardDismissMode = .interactive
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        scroll.addSubview(stack)
        let centred = stack.centerYAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerYAnchor)
        centred.priority = .defaultLow
        let wide = stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -48)
        wide.priority = .defaultHigh
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: scroll.contentLayoutGuide.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.centerXAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerXAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            centred, wide,
        ])
        model.onChange = { [weak self] in self?.update() }
        model.start()
        update()
    }

    /// What the server allows decides what shows: the password fields, the browser button, both.
    private func update() {
        let methods = model.methods
        serverNote.text = switch model.state {
        case .checking: nil
        case .unreachable: String(localized: "No Matrix server answers there.")
        case .ready(let methods) where !methods.password && !methods.browser: String(localized: "This server does not allow signing in from apps.")
        case .ready: nil
        }
        let byPassword = methods.password
        // the fields fade and slide in and out as the server's answer comes (not on the first draw).
        let shown: [(UIView, Bool)] = [(serverNote, serverNote.text != nil), (credentials, byPassword), (signIn, byPassword),
                                       (browser, methods.browser)]
        let change = {
            for (view, visible) in shown where view.isHidden == visible {
                view.isHidden = !visible
                view.alpha = visible ? 1 : 0
            }
            self.view.layoutIfNeeded()
        }
        if view.window == nil { change() } else {
            UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0, options: [.beginFromCurrentState],
                           animations: change)
        }
        // with only the server's page, it is the main button.
        var page: UIButton.Configuration = byPassword ? .glass() : .prominentGlass()
        page.title = String(localized: "Sign In on the Server's Page")
        page.image = UIImage(systemName: "safari")
        page.imagePadding = 8
        page.buttonSize = .large
        page.showsActivityIndicator = model.isSigningIn && !byPassword
        browser.configuration = page
        var main: UIButton.Configuration = .prominentGlass()
        main.title = String(localized: "Sign In")
        main.buttonSize = .large
        main.showsActivityIndicator = model.isSigningIn && byPassword
        signIn.configuration = main
        for control in [signIn, browser, server, user, password] as [UIControl] { control.isEnabled = !model.isSigningIn }
    }

    /// Return moves to the next field; on the password it signs in.
    func textFieldShouldReturn(_ field: UITextField) -> Bool {
        switch field {
        case server: if !credentials.isHidden { user.becomeFirstResponder() } else { field.resignFirstResponder() }
        case user: password.becomeFirstResponder()
        default: signInWithPassword()
        }
        return true
    }

    private func signInWithPassword() {
        guard let name = user.text, !name.isEmpty, let secret = password.text, !secret.isEmpty else {
            status.text = String(localized: "Enter your user name and password.")
            return
        }
        status.text = nil
        Task {
            do {
                try await model.signIn(user: name, password: secret)
                signedIn()
            } catch {
                status.text = error.localizedDescription
            }
        }
    }

    private func signInInBrowser() {
        guard let window = view.window else { return }
        status.text = nil
        Task {
            do {
                try await model.signInInBrowser(presentingFrom: window)
                signedIn()
            } catch is CancellationError {
            } catch {
                status.text = error.localizedDescription
            }
        }
    }
}
