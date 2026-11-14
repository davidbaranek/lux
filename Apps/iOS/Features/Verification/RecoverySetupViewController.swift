import LuxCore
import UIKit

/// Sets up recovery for an account that has none, as Element X does: the core makes a recovery
/// key and backs this device's message keys up under it; the user saves the key, the only way a
/// new device reads the history when no other device is at hand.
final class RecoverySetupViewController: UIViewController {
    private let security: SecurityModel
    private let symbol = UIImageView(image: UIImage(systemName: "key.viewfinder"))
    private let heading = UILabel()
    private let explanation = UILabel()
    private let keyLabel = UILabel()
    private let keyBox = UIView()
    private let message = UILabel()
    private lazy var setUp = UIButton(configuration: .prominentGlass(), primaryAction: UIAction { [weak self] _ in self?.start() })
    private lazy var copy = UIButton(configuration: .glass(), primaryAction: UIAction { [weak self] _ in self?.copyKey() })
    private lazy var share = UIButton(configuration: .glass(), primaryAction: UIAction { [weak self] action in self?.shareKey(from: action.sender) })
    private lazy var done = UIButton(configuration: .prominentGlass(), primaryAction: UIAction { [weak self] _ in self?.finish() })
    private var key: String?

    init(security: SecurityModel) {
        self.security = security
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Set Up Recovery")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        navigationItem.largeTitleDisplayMode = .never
        if navigationController?.viewControllers.first === self {
            navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
                self?.dismiss(animated: true)
            })
        }
        symbol.preferredSymbolConfiguration = .init(pointSize: 52, weight: .regular)
        symbol.contentMode = .scaleAspectFit
        heading.font = .preferredFont(forTextStyle: .title2).bold
        explanation.font = .preferredFont(forTextStyle: .body)
        explanation.textColor = .secondaryLabel
        message.font = .preferredFont(forTextStyle: .footnote)
        for label in [heading, explanation, message] {
            label.textAlignment = .center
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
        }
        keyLabel.font = .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize, weight: .medium)
        keyLabel.numberOfLines = 0
        keyLabel.textAlignment = .center
        keyLabel.translatesAutoresizingMaskIntoConstraints = false
        keyLabel.accessibilityLabel = String(localized: "Recovery key")
        keyBox.backgroundColor = .secondarySystemGroupedBackground
        keyBox.layer.cornerRadius = 14
        keyBox.layer.cornerCurve = .continuous
        keyBox.addSubview(keyLabel)
        NSLayoutConstraint.activate([
            keyLabel.topAnchor.constraint(equalTo: keyBox.topAnchor, constant: 16),
            keyLabel.bottomAnchor.constraint(equalTo: keyBox.bottomAnchor, constant: -16),
            keyLabel.leadingAnchor.constraint(equalTo: keyBox.leadingAnchor, constant: 16),
            keyLabel.trailingAnchor.constraint(equalTo: keyBox.trailingAnchor, constant: -16),
        ])
        setUp.configuration?.title = String(localized: "Set Up Recovery")
        copy.configuration?.title = String(localized: "Copy")
        copy.configuration?.image = UIImage(systemName: "doc.on.doc")
        copy.configuration?.imagePadding = 6
        share.configuration?.title = String(localized: "Save…")
        share.configuration?.image = UIImage(systemName: "square.and.arrow.up")
        share.configuration?.imagePadding = 6
        done.configuration?.title = String(localized: "Done")
        let keyActions = UIStackView(arrangedSubviews: [copy, share])
        keyActions.distribution = .fillEqually
        keyActions.spacing = 10
        let text = UIStackView(arrangedSubviews: [symbol, heading, explanation])
        text.axis = .vertical
        text.spacing = 14
        let stack = UIStackView(arrangedSubviews: [text, keyBox, keyActions, setUp, done, message])
        stack.axis = .vertical
        stack.spacing = 20
        stack.setCustomSpacing(32, after: text)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.readableContentGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.readableContentGuide.trailingAnchor),
        ])
        showIntroduction()
    }

    private func showIntroduction() {
        heading.text = String(localized: "Keep your messages safe")
        explanation.text = String(localized: """
            Lux makes a recovery key and backs up your message keys with it, encrypted. With the key, \
            a new device reads your encrypted history even when no other device is at hand.
            """)
        keyBox.isHidden = true
        copy.superview?.isHidden = true
        done.isHidden = true
        setUp.isHidden = false
    }

    private func start() {
        setUp.isEnabled = false
        setUp.configuration?.showsActivityIndicator = true
        message.text = nil
        Task {
            defer {
                setUp.isEnabled = true
                setUp.configuration?.showsActivityIndicator = false
            }
            do {
                show(key: try await security.setUpRecovery())
            } catch {
                message.textColor = .systemRed
                message.text = error.localizedDescription
            }
        }
    }

    private func show(key: String) {
        self.key = key
        symbol.image = UIImage(systemName: "checkmark.shield.fill")
        symbol.tintColor = .systemGreen
        heading.text = String(localized: "Save your recovery key")
        explanation.text = String(localized: """
            Keep it somewhere safe, such as a password manager. Anyone with it can read your encrypted \
            messages; without it, and with no other device, they cannot be recovered.
            """)
        keyLabel.text = key
        keyBox.isHidden = false
        copy.superview?.isHidden = false
        setUp.isHidden = true
        done.isHidden = false
        // the key must be saved before the screen goes.
        done.isEnabled = false
        isModalInPresentation = true
        navigationItem.leftBarButtonItem = nil
        navigationItem.hidesBackButton = true
        UIAccessibility.post(notification: .screenChanged, argument: heading)
    }

    private func copyKey() {
        guard let key else { return }
        UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: key]],
                                      options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)])
        saved(String(localized: "Copied. It leaves the clipboard in two minutes."))
    }

    private func shareKey(from sender: Any?) {
        guard let key else { return }
        let sheet = UIActivityViewController(activityItems: [key], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceItem = sender as? UIView
        sheet.completionWithItemsHandler = { [weak self] _, completed, _, _ in
            if completed { self?.saved(String(localized: "Saved.")) }
        }
        present(sheet, animated: true)
    }

    private func saved(_ words: String) {
        message.textColor = .secondaryLabel
        message.text = words
        done.isEnabled = true
    }

    private func finish() {
        if navigationController?.viewControllers.first === self {
            dismiss(animated: true)
        } else {
            navigationController?.popViewController(animated: true)
        }
    }
}
