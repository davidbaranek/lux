import LuxCore
import UIKit

/// Verify this device from another one: wait for it to accept, compare the emojis, answer.
final class VerificationViewController: UIViewController {
    private let model: VerificationModel
    private let done: () -> Void
    private let status = UILabel()
    private let detail = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let emojis = UIStackView()
    private lazy var match = UIButton(configuration: .prominentGlass(), primaryAction: UIAction { [weak self] _ in self?.model.confirm() })
    private lazy var noMatch = UIButton(configuration: .glass(), primaryAction: UIAction { [weak self] _ in self?.model.deny() })

    init(model: VerificationModel, done: @escaping () -> Void) {
        self.model = model
        self.done = done
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Verify This Device")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
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
        let buttons = UIStackView(arrangedSubviews: [match, noMatch])
        buttons.axis = .vertical
        buttons.spacing = 10
        let stack = UIStackView(arrangedSubviews: [spinner, status, detail, emojis, buttons])
        stack.axis = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.readableContentGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.readableContentGuide.trailingAnchor),
        ])
        model.onStep = { [weak self] step in self?.show(step) }
        show(.waiting)
        model.start()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isMovingFromParent, model.step != .done { model.cancel() }
    }

    private func show(_ step: VerificationStep) {
        spinner.isHidden = true
        emojis.isHidden = true
        match.superview?.isHidden = true
        switch step {
        case .waiting, .accepted:
            spinner.isHidden = false
            spinner.startAnimating()
            status.text = step == .waiting ? String(localized: "Waiting for your other device") : String(localized: "Connecting…")
            detail.text = String(localized: "Open Lux or Element on a device you are signed in on, and accept the request.")
        case .compare(let list):
            status.text = String(localized: "Do these match?")
            detail.text = String(localized: "Compare them with your other device, in the same order.")
            emojis.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for emoji in list { emojis.addArrangedSubview(EmojiTile(emoji)) }
            emojis.isHidden = false
            match.superview?.isHidden = false
        case .done:
            status.text = String(localized: "This device is verified")
            detail.text = String(localized: "Your other devices now share their message keys with it.")
            done()
        case .cancelled:
            status.text = String(localized: "Verification stopped")
            detail.text = String(localized: "Nothing was changed. You can start again.")
        case .failed:
            status.text = String(localized: "Verification failed")
            detail.text = String(localized: "Make sure both devices are online, then try again.")
        }
        UIAccessibility.post(notification: .screenChanged, argument: status)
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
