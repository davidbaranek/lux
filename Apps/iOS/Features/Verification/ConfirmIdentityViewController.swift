import LuxCore
import UIKit

/// After signing in, while this device is not verified: prove it is the account's, with another
/// of its devices (comparing emojis) or with the recovery key. It closes once the device is
/// verified, by either.
final class ConfirmIdentityViewController: UIViewController {
    private let session: Session
    private let withRecoveryKey: Bool
    private var observation: AnyObject?

    init(session: Session, withRecoveryKey: Bool) {
        self.session = session
        self.withRecoveryKey = withRecoveryKey
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Confirm It's You")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        navigationItem.largeTitleDisplayMode = .never
        let symbol = UIImageView(image: UIImage(systemName: "lock.shield"))
        symbol.preferredSymbolConfiguration = .init(pointSize: 52, weight: .regular)
        symbol.contentMode = .scaleAspectFit
        let heading = UILabel()
        heading.text = String(localized: "Verify this device")
        heading.font = .preferredFont(forTextStyle: .title2).bold
        let explanation = UILabel()
        explanation.text = withRecoveryKey
            ? String(localized: "Your encrypted messages stay locked on this device until you verify it, with another device you are signed in on or with your recovery key.")
            : String(localized: "Your encrypted messages stay locked on this device until you verify it with another device you are signed in on.")
        explanation.font = .preferredFont(forTextStyle: .body)
        explanation.textColor = .secondaryLabel
        for label in [heading, explanation] {
            label.textAlignment = .center
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
        }
        let otherDevice = UIButton(configuration: .prominentGlass(), primaryAction: UIAction { [weak self] _ in self?.useAnotherDevice() })
        otherDevice.configuration?.title = String(localized: "Use Another Device")
        otherDevice.configuration?.image = UIImage(systemName: "iphone.and.arrow.forward")
        otherDevice.configuration?.imagePadding = 8
        let recoveryKey = UIButton(configuration: .glass(), primaryAction: UIAction { [weak self] _ in self?.enterRecoveryKey() })
        recoveryKey.configuration?.title = String(localized: "Enter Recovery Key")
        recoveryKey.configuration?.image = UIImage(systemName: "key")
        recoveryKey.configuration?.imagePadding = 8
        recoveryKey.isHidden = !withRecoveryKey
        let later = UIButton(configuration: .plain(), primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        later.configuration?.title = String(localized: "Not Now")
        let buttons = UIStackView(arrangedSubviews: [otherDevice, recoveryKey, later])
        buttons.axis = .vertical
        buttons.spacing = 10
        let text = UIStackView(arrangedSubviews: [symbol, heading, explanation])
        text.axis = .vertical
        text.spacing = 14
        let stack = UIStackView(arrangedSubviews: [text, buttons])
        stack.axis = .vertical
        stack.spacing = 32
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.readableContentGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.readableContentGuide.trailingAnchor),
        ])
        // verified meanwhile (the recovery key, another device's request): nothing left to do.
        observation = session.security?.changes.observe { [weak self] in
            guard let self, session.security?.setup == .ready || session.security?.setup == .setUpRecovery else { return }
            if navigationController?.topViewController === self { dismiss(animated: true) }
        }
    }

    private func useAnotherDevice() {
        let verification = VerificationViewController(model: VerificationModel(session: session, kind: .thisDevice)) { [weak self] in
            self?.finishSoon()
        }
        navigationController?.pushViewController(verification, animated: true)
    }

    private func enterRecoveryKey() {
        let recovery = RecoveryKeyViewController(model: SettingsModel(session: session)) { [weak self] in
            self?.finishSoon()
        }
        navigationController?.pushViewController(recovery, animated: true)
    }

    /// Verified: the success shows a moment, then the sheet goes.
    private func finishSoon() {
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            dismiss(animated: true)
        }
    }
}
