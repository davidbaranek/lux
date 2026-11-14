import CoreImage.CIFilterBuiltins
import LuxCore
import SafariServices
import UIKit

/// Signing in to one network, as a sheet: each step the bridge asks for in turn, the network's
/// own website to sign in on (what the bridge needs is read from it), a form, or a QR code or code
/// for the phone while the bridge waits, then a check mark. Closing it cancels the sign-in.
final class NetworkSignInViewController: UINavigationController, UIAdaptivePresentationControllerDelegate {
    private let signIn: NetworkSignIn
    private let finished: () -> Void
    private var isDone = false

    init(signIn: NetworkSignIn, finished: @escaping () -> Void) {
        self.signIn = signIn
        self.finished = finished
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
        sheetPresentationController?.prefersGrabberVisible = true
        presentationController?.delegate = self
        setViewControllers([StepViewController(network: signIn.offer, content: .waiting)], animated: false)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        run { try await self.signIn.start() }
    }

    /// Runs a call to the bridge, and shows the step it answers with.
    private func run(_ call: @escaping () async throws -> NetworkLoginStep) {
        Task {
            do {
                show(try await call())
            } catch {
                failed(error)
            }
        }
    }

    private func show(_ step: NetworkLoginStep) {
        let offer = signIn.offer
        switch step {
        case .website(let website):
            push(WebsiteStepViewController(network: offer, step: website) { [weak self] values in
                guard let self else { return }
                run { try await self.signIn.answer(website.id, values: values) }
            })
        case .form(let form):
            push(FormStepViewController(network: offer, step: form) { [weak self] values in
                guard let self else { return }
                run { try await self.signIn.answer(form.id, values: values) }
            })
        case .show(let shown):
            push(StepViewController(network: offer, content: .shown(shown)))
            run { try await self.signIn.wait(shown.id) }
        case .done(let message):
            isDone = true
            push(StepViewController(network: offer, content: .done(message)))
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                dismiss(animated: true) { self.finished() }
            }
        case .unsupported:
            failed(BridgeFailure.refused(String(localized: "Lux cannot take this way of signing in yet. Pick another way in Settings → Networks.")))
        }
    }

    private func push(_ step: UIViewController) {
        step.navigationItem.hidesBackButton = true
        step.navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
            self?.close()
        })
        setViewControllers([step], animated: true)
    }

    private func failed(_ error: any Error) {
        let failure = error as? BridgeFailure
        let alert = UIAlertController(title: String(localized: "Could not sign in to \(signIn.offer.name)"),
                                      message: error.localizedDescription, preferredStyle: .alert)
        if failure?.isServerSetup == true {
            alert.addAction(UIAlertAction(title: String(localized: "How to Set It Up"), style: .default) { [weak self] _ in
                self?.close { presenter in
                    presenter?.present(SFSafariViewController(url: BridgeSetup.guide), animated: true)
                }
            })
            alert.addAction(UIAlertAction(title: String(localized: "Close"), style: .cancel) { [weak self] _ in self?.close() })
        } else if case .refused? = failure, topViewController is FormStepViewController {
            // a wrong code or PIN: the form stays, to try again.
            alert.addAction(UIAlertAction(title: String(localized: "Try Again"), style: .cancel))
        } else {
            alert.addAction(UIAlertAction(title: String(localized: "Start Over"), style: .default) { [weak self] _ in
                guard let self else { return }
                setViewControllers([StepViewController(network: signIn.offer, content: .waiting)], animated: true)
                run { try await self.signIn.start() }
            })
            alert.addAction(UIAlertAction(title: String(localized: "Close"), style: .cancel) { [weak self] _ in self?.close() })
        }
        (topViewController as? FormStepViewController)?.isWorking = false
        present(alert, animated: true)
    }

    /// Closes the sheet, cancelling the sign-in unless it is done; `then` gets what showed it.
    private func close(then: ((UIViewController?) -> Void)? = nil) {
        if !isDone { signIn.cancel() }
        let presenter = presentingViewController
        dismiss(animated: true) { then?(presenter) }
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        if !isDone { signIn.cancel() }
    }
}

/// A step that shows something: a spinner while the bridge answers, a QR code or code while it
/// waits for the phone, or the check mark at the end.
private final class StepViewController: UIViewController {
    enum Content {
        case waiting
        case shown(NetworkLoginStep.Shown)
        case done(String)
    }

    private let network: NetworkOffer
    private let content: Content

    init(network: NetworkOffer, content: Content) {
        self.network = network
        self.content = content
        super.init(nibName: nil, bundle: nil)
        title = network.name
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
        ])
        let logo = UIImageView(image: NetworkImage.image(network.network))
        logo.contentMode = .scaleAspectFit
        logo.widthAnchor.constraint(equalToConstant: 56).isActive = true
        logo.heightAnchor.constraint(equalToConstant: 56).isActive = true
        stack.addArrangedSubview(logo)

        switch content {
        case .waiting:
            let spinner = UIActivityIndicatorView(style: .large)
            spinner.startAnimating()
            stack.addArrangedSubview(spinner)
        case .shown(let shown):
            stack.addArrangedSubview(label(shown.id.instructions.isEmpty ? String(localized: "Open \(network.name) on your phone.") : shown.id.instructions,
                                           style: .body))
            switch shown.what {
            case .qrCode(let data):
                let code = UIImageView(image: Self.qrCode(data))
                code.layer.magnificationFilter = .nearest
                code.widthAnchor.constraint(equalToConstant: 240).isActive = true
                code.heightAnchor.constraint(equalToConstant: 240).isActive = true
                code.accessibilityLabel = String(localized: "QR code to scan with \(network.name)")
                stack.addArrangedSubview(code)
            case .code(let text), .emoji(let text, _):
                let code = label(text, style: .largeTitle)
                code.font = .monospacedSystemFont(ofSize: 34, weight: .semibold)
                stack.addArrangedSubview(code)
            case .nothing:
                break
            }
            let waiting = UIStackView(arrangedSubviews: [UIActivityIndicatorView(style: .medium), label(String(localized: "Waiting for your phone…"), style: .footnote)])
            (waiting.arrangedSubviews.first as? UIActivityIndicatorView)?.startAnimating()
            waiting.spacing = 8
            stack.addArrangedSubview(waiting)
        case .done(let message):
            let check = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))
            check.tintColor = .systemGreen
            check.preferredSymbolConfiguration = .init(pointSize: 56)
            stack.addArrangedSubview(check)
            stack.addArrangedSubview(label(String(localized: "\(network.name) is connected"), style: .title2))
            if !message.isEmpty { stack.addArrangedSubview(label(message, style: .footnote)) }
            stack.addArrangedSubview(label(String(localized: "Its chats and their history arrive over the next minutes."), style: .footnote))
        }
    }

    private func label(_ text: String, style: UIFont.TextStyle) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: style)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = style == .footnote ? .secondaryLabel : .label
        label.numberOfLines = 0
        label.textAlignment = .center
        return label
    }

    static func qrCode(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let image = filter.outputImage,
              let cgImage = CIContext().createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

/// The network's website: the user signs in there as on any browser, and the sign-in goes on
/// by itself once the page has what the bridge needs.
private final class WebsiteStepViewController: UIViewController {
    private let reader: WebsiteLoginReader
    private let network: NetworkOffer
    private let step: NetworkLoginStep.Website
    private let answer: ([String: String]) -> Void
    private var answered = false
    private var checking: Timer?

    init(network: NetworkOffer, step: NetworkLoginStep.Website, answer: @escaping ([String: String]) -> Void) {
        self.network = network
        self.step = step
        self.answer = answer
        var send: (([String: String]) -> Void)?
        reader = WebsiteLoginReader(step: step) { values in send?(values) }
        super.init(nibName: nil, bundle: nil)
        send = { [weak self] values in self?.send(values) }
        title = network.name
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let web = reader.webView
        web.translatesAutoresizingMaskIntoConstraints = false
        web.isHidden = step.hidden
        view.addSubview(web)
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            web.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            web.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        navigationItem.prompt = String(localized: "Sign in to \(network.name). Lux continues by itself once you are in.")
        // the page may never reach the address the bridge waits for: once it has what is needed,
        // the user can go on by hand.
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: String(localized: "Continue"), primaryAction: UIAction { [weak self] _ in
            guard let self, reader.hasRequired else { return }
            send(reader.readValues)
        })
        navigationItem.leftBarButtonItem?.isEnabled = false
        checking = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.navigationItem.leftBarButtonItem?.isEnabled = self.reader.hasRequired
            }
        }
        reader.start()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        checking?.invalidate()
        reader.stop()
    }

    private func send(_ values: [String: String]) {
        guard !answered else { return }
        answered = true
        reader.stop()
        answer(values)
    }
}

/// A form the bridge asks for (a phone number, a code, a PIN): one field each, checked as typed.
private final class FormStepViewController: UIViewController, UITextFieldDelegate {
    private let step: NetworkLoginStep.Form
    private let answer: ([String: String]) -> Void
    private var fields: [String: UITextField] = [:]
    private let send = UIButton(configuration: .prominentGlass())
    private let skip = UIButton(configuration: .plain())

    var isWorking = false {
        didSet {
            send.configuration?.showsActivityIndicator = isWorking
            send.isEnabled = !isWorking && isValid
        }
    }

    init(network: NetworkOffer, step: NetworkLoginStep.Form, answer: @escaping ([String: String]) -> Void) {
        self.step = step
        self.answer = answer
        super.init(nibName: nil, bundle: nil)
        title = network.name
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
        ])
        if !step.id.instructions.isEmpty {
            let instructions = UILabel()
            instructions.text = step.id.instructions
            instructions.font = .preferredFont(forTextStyle: .body)
            instructions.adjustsFontForContentSizeCategory = true
            instructions.numberOfLines = 0
            stack.addArrangedSubview(instructions)
        }
        for field in step.fields {
            let text = UITextField()
            text.placeholder = field.name
            text.text = field.defaultValue
            text.borderStyle = .roundedRect
            text.font = .preferredFont(forTextStyle: .body)
            text.adjustsFontForContentSizeCategory = true
            text.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            text.delegate = self
            switch field.kind {
            case .password:
                text.isSecureTextEntry = true
                text.textContentType = .password
                if field.pattern?.contains("[0-9]") == true { text.keyboardType = .numberPad }
            case .phoneNumber:
                text.keyboardType = .phonePad
                text.textContentType = .telephoneNumber
            case .email:
                text.keyboardType = .emailAddress
                text.textContentType = .emailAddress
                text.autocapitalizationType = .none
            case .code:
                text.keyboardType = .numberPad
                text.textContentType = .oneTimeCode
            case .username:
                text.textContentType = .username
                text.autocapitalizationType = .none
            case .text, .choice:
                text.autocapitalizationType = .none
            }
            text.autocorrectionType = .no
            text.addAction(UIAction { [weak self] _ in self?.validate() }, for: .editingChanged)
            fields[field.id] = text
            stack.addArrangedSubview(text)
            if !field.description.isEmpty {
                let description = UILabel()
                description.text = field.description
                description.font = .preferredFont(forTextStyle: .footnote)
                description.textColor = .secondaryLabel
                description.numberOfLines = 0
                stack.addArrangedSubview(description)
            }
        }
        send.configuration?.title = String(localized: "Continue")
        send.heightAnchor.constraint(greaterThanOrEqualToConstant: 50).isActive = true
        send.addAction(UIAction { [weak self] _ in self?.submit() }, for: .primaryActionTriggered)
        stack.setCustomSpacing(24, after: stack.arrangedSubviews.last ?? stack)
        stack.addArrangedSubview(send)
        if step.fields.allSatisfy(\.optional) {
            skip.configuration?.title = String(localized: "Skip")
            skip.addAction(UIAction { [weak self] _ in self?.submit(skipping: true) }, for: .primaryActionTriggered)
            stack.addArrangedSubview(skip)
        }
        validate()
        fields[step.fields.first?.id ?? ""]?.becomeFirstResponder()
    }

    private var isValid: Bool {
        step.fields.allSatisfy { $0.accepts(fields[$0.id]?.text ?? "") }
    }

    private func validate() {
        send.isEnabled = !isWorking && isValid
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if isValid { submit() }
        return false
    }

    private func submit(skipping: Bool = false) {
        guard !isWorking, skipping || isValid else { return }
        isWorking = true
        var values: [String: String] = [:]
        for field in step.fields { values[field.id] = skipping ? "" : fields[field.id]?.text ?? "" }
        answer(values)
    }
}
