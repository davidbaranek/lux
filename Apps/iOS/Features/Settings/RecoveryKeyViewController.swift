import LuxCore
import UIKit

/// The recovery key that opens the account's key backup, so this device reads encrypted messages
/// from before it signed in.
final class RecoveryKeyViewController: UIViewController, UITextViewDelegate {
    private let model: SettingsModel
    /// The key opened the backup (and verified this device).
    private let recovered: () -> Void
    private var observation: AnyObject?
    private let status = UILabel()
    private let key = UITextView()
    private let message = UILabel()
    private lazy var unlock = UIButton(configuration: .prominentGlass(), primaryAction: UIAction { [weak self] _ in self?.recover() })

    init(model: SettingsModel, recovered: @escaping () -> Void = {}) {
        self.model = model
        self.recovered = recovered
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Key Backup")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        let explanation = UILabel()
        explanation.text = String(localized: """
            Encrypted messages from before this device signed in are in your account's key backup. \
            Enter the recovery key you saved when you set it up (in Lux, Element or another app).
            """)
        explanation.numberOfLines = 0
        explanation.textColor = .secondaryLabel
        explanation.font = .preferredFont(forTextStyle: .subheadline)
        status.font = .preferredFont(forTextStyle: .headline)
        key.font = .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize, weight: .regular)
        key.autocorrectionType = .no
        key.autocapitalizationType = .none
        key.smartDashesType = .no
        key.spellCheckingType = .no
        key.backgroundColor = .secondarySystemGroupedBackground
        key.layer.cornerRadius = 12
        key.layer.cornerCurve = .continuous
        key.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        key.delegate = self
        key.accessibilityLabel = String(localized: "Recovery key")
        key.heightAnchor.constraint(equalToConstant: 96).isActive = true
        message.numberOfLines = 0
        message.font = .preferredFont(forTextStyle: .footnote)
        unlock.configuration?.title = String(localized: "Unlock")
        unlock.isEnabled = false
        for label in [explanation, status, message] { label.adjustsFontForContentSizeCategory = true }

        let stack = UIStackView(arrangedSubviews: [status, explanation, key, unlock, message])
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: view.readableContentGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.readableContentGuide.trailingAnchor),
        ])
        observation = model.changes.observe { [weak self] in self?.update() }
        update()
        Task { await model.load() }
    }

    private func update() {
        status.text = model.recovery.title
        let open = model.recovery == .enabled
        key.isEditable = !open
        unlock.isEnabled = !open && !key.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func textViewDidChange(_ textView: UITextView) { update() }

    private func recover() {
        unlock.isEnabled = false
        unlock.configuration?.showsActivityIndicator = true
        message.text = nil
        let text = key.text ?? ""
        Task {
            defer {
                unlock.configuration?.showsActivityIndicator = false
                update()
            }
            do {
                try await model.recover(key: text)
                key.text = ""
                message.textColor = .secondaryLabel
                message.text = String(localized: "Unlocked. Encrypted messages appear as their chats load.")
                recovered()
            } catch {
                message.textColor = .systemRed
                message.text = error.localizedDescription
            }
        }
    }
}
