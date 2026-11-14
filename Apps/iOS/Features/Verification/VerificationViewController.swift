import LuxCore
import UIKit

/// A verification with another of the account's devices: this device from any of them, another
/// device from this one, or another device's request, accepted here. Wait for the other device,
/// compare the emojis, answer.
final class VerificationViewController: UIViewController {
    private let model: VerificationModel
    private let done: () -> Void
    private let symbol = UIImageView()
    private let status = UILabel()
    private let detail = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let emojis = UIStackView()
    private lazy var match = UIButton(configuration: .prominentGlass(), primaryAction: UIAction { [weak self] _ in self?.model.confirm() })
    private lazy var noMatch = UIButton(configuration: .glass(), primaryAction: UIAction { [weak self] _ in self?.model.deny() })
    private lazy var accept = UIButton(configuration: .prominentGlass(), primaryAction: UIAction { [weak self] _ in self?.model.accept() })
    private lazy var decline = UIButton(configuration: .glass(), primaryAction: UIAction { [weak self] _ in self?.close() })
    private var compareButtons: UIStackView!
    private var requestButtons: UIStackView!

    init(model: VerificationModel, done: @escaping () -> Void = {}) {
        self.model = model
        self.done = done
        super.init(nibName: nil, bundle: nil)
        title = switch model.kind {
        case .thisDevice: String(localized: "Verify This Device")
        case .device: String(localized: "Verify Device")
        case .request: String(localized: "Verification Request")
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        symbol.preferredSymbolConfiguration = .init(pointSize: 44, weight: .regular)
        symbol.contentMode = .scaleAspectFit
        status.font = .preferredFont(forTextStyle: .title3).bold
        status.textAlignment = .center
        status.numberOfLines = 0
        detail.font = .preferredFont(forTextStyle: .body)
        detail.textColor = .secondaryLabel
        detail.textAlignment = .center
        detail.numberOfLines = 0
        for label in [status, detail] { label.adjustsFontForContentSizeCategory = true }
        emojis.axis = .horizontal
        emojis.distribution = .fillEqually
        emojis.spacing = 4
        match.configuration?.title = String(localized: "They Match")
        noMatch.configuration?.title = String(localized: "They Don't Match")
        accept.configuration?.title = String(localized: "Accept")
        decline.configuration?.title = String(localized: "Decline")
        compareButtons = Self.column([match, noMatch])
        requestButtons = Self.column([accept, decline])
        let stack = UIStackView(arrangedSubviews: [symbol, spinner, status, detail, emojis, compareButtons, requestButtons])
        stack.axis = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.readableContentGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.readableContentGuide.trailingAnchor),
        ])
        // presented on its own (another device's request): it closes itself.
        if navigationController?.viewControllers.first === self {
            navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in self?.close() })
        }
        model.onStep = { [weak self] step in self?.show(step) }
        show(model.step ?? (isRequest ? .requested : .waiting))
        model.start()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // gone back, or swiped away: the other device stops waiting.
        let leaving = isMovingFromParent || navigationController?.isBeingDismissed == true
        if leaving, model.step?.isFinal != true { model.cancel() }
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

    private static func column(_ buttons: [UIButton]) -> UIStackView {
        let column = UIStackView(arrangedSubviews: buttons)
        column.axis = .vertical
        column.spacing = 10
        return column
    }

    private func show(_ step: VerificationStep) {
        spinner.isHidden = true
        spinner.stopAnimating()
        symbol.isHidden = true
        symbol.tintColor = .tintColor
        emojis.isHidden = true
        compareButtons.isHidden = true
        requestButtons.isHidden = true
        switch step {
        case .requested:
            symbol.image = UIImage(systemName: "lock.shield")
            symbol.isHidden = false
            status.text = otherName.map { String(localized: "\($0) wants to verify") } ?? String(localized: "Another device wants to verify")
            detail.text = String(localized: "Accept only if you started this on your other device. You will compare emojis on both.")
            requestButtons.isHidden = false
        case .waiting, .accepted:
            spinner.isHidden = false
            spinner.startAnimating()
            if step == .accepted {
                status.text = String(localized: "Connecting…")
            } else if let otherName, !isRequest {
                status.text = String(localized: "Waiting for \(otherName)")
            } else {
                status.text = String(localized: "Waiting for your other device")
            }
            detail.text = switch model.kind {
            case .thisDevice: String(localized: "Open Lux or Element on a device you are signed in on, and accept the request.")
            case .device: String(localized: "Accept the request on that device.")
            case .request: String(localized: "Keep both devices open.")
            }
        case .compare(let list):
            status.text = String(localized: "Do these match?")
            detail.text = String(localized: "Compare them with your other device, in the same order.")
            emojis.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for emoji in list { emojis.addArrangedSubview(EmojiTile(emoji)) }
            emojis.isHidden = false
            compareButtons.isHidden = false
        case .done:
            symbol.image = UIImage(systemName: "checkmark.shield.fill")
            symbol.tintColor = .systemGreen
            symbol.isHidden = false
            if model.kind == .thisDevice {
                status.text = String(localized: "This device is verified")
                detail.text = String(localized: "Your other devices now share their message keys with it.")
            } else {
                status.text = otherName.map { String(localized: "\($0) is verified") } ?? String(localized: "Verified")
                detail.text = String(localized: "Your devices trust each other and share their message keys.")
            }
            done()
        case .cancelled:
            status.text = String(localized: "Verification stopped")
            detail.text = String(localized: "Nothing was changed. You can start again.")
        case .failed:
            symbol.image = UIImage(systemName: "xmark.shield")
            symbol.tintColor = .systemRed
            symbol.isHidden = false
            status.text = String(localized: "Verification failed")
            detail.text = String(localized: "Make sure both devices are online, then try again.")
        }
        if step.isFinal, navigationItem.leftBarButtonItem != nil {
            navigationItem.leftBarButtonItem = nil
            navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.close() })
        }
        UIAccessibility.post(notification: .screenChanged, argument: status)
    }

    /// Closes the screen presented on its own; a verification still going is cancelled (a request
    /// declined).
    private func close() {
        if model.step?.isFinal != true { model.cancel() }
        navigationController?.dismiss(animated: true)
    }
}

/// One emoji and its name, as both devices show it.
private final class EmojiTile: UIStackView {
    init(_ emoji: VerificationEmoji) {
        super.init(frame: .zero)
        axis = .vertical
        alignment = .center
        spacing = 4
        let symbol = UILabel()
        symbol.text = emoji.symbol
        symbol.font = .systemFont(ofSize: 34)
        let name = UILabel()
        name.text = emoji.name
        name.font = .preferredFont(forTextStyle: .caption2)
        name.textColor = .secondaryLabel
        name.adjustsFontSizeToFitWidth = true
        addArrangedSubview(symbol)
        addArrangedSubview(name)
        isAccessibilityElement = true
        accessibilityLabel = emoji.name
    }

    @available(*, unavailable) required init(coder: NSCoder) { fatalError() }
}
