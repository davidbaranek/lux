import LuxCore
import UIKit

/// The account's devices: which are verified, a verification for one that is not, and signing
/// another out (swipe, or its menu).
final class DevicesViewController: UIViewController, UICollectionViewDelegate {
    private let session: Session
    private let security: SecurityModel
    private var observation: AnyObject?
    private var activation: NSObjectProtocol?
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, OwnDevice>!

    init(session: Session, security: SecurityModel) {
        self.session = session
        self.security = security
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Devices")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        var layout = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        layout.footerMode = .supplementary
        layout.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            guard let self, let device = dataSource.itemIdentifier(for: indexPath), !device.isThisDevice else { return nil }
            let signOut = UIContextualAction(style: .destructive, title: String(localized: "Sign Out")) { [weak self] _, _, done in
                self?.signOut(device)
                done(true)
            }
            return UISwipeActionsConfiguration(actions: [signOut])
        }
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: layout))
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.delegate = self
        view.addSubview(collectionView)
        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, OwnDevice> { cell, _, device in
            var content = UIListContentConfiguration.subtitleCell()
            content.text = device.title
            let state = device.isVerified ? String(localized: "Verified") : String(localized: "Not verified")
            content.secondaryText = device.isThisDevice ? String(localized: "This device · \(state)") : state
            content.secondaryTextProperties.color = .secondaryLabel
            content.image = UIImage(systemName: device.isVerified ? "checkmark.shield" : "exclamationmark.shield")
            content.imageProperties.tintColor = device.isVerified ? .systemGreen : .systemOrange
            cell.contentConfiguration = content
            cell.accessories = device.isThisDevice || device.isVerified ? [] : [.disclosureIndicator()]
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionFooter) { view, _, _ in
            var content = UIListContentConfiguration.footer()
            content.text = String(localized: "A verified device can read your encrypted messages. Verify a device only if it is yours: you compare emojis on both. Swipe a device you no longer use to sign it out.")
            view.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, device in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: device)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
        observation = security.changes.observe { [weak self] in self?.update() }
        // back from the account page in the browser: a device may have signed out there.
        activation = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.loadDevices()
            }
        }
        update()
    }

    isolated deinit {
        if let activation { NotificationCenter.default.removeObserver(activation) }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // back from a verification: the device may be verified now.
        loadDevices()
    }

    private func loadDevices() {
        Task {
            do { try await security.loadDevices() } catch { report(error, of: "devices") }
        }
    }

    private func update() {
        var snapshot = NSDiffableDataSourceSnapshot<Int, OwnDevice>()
        snapshot.appendSections([0])
        snapshot.appendItems(security.devices)
        dataSource.apply(snapshot, animatingDifferences: view.window != nil)
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first, let device = dataSource.itemIdentifier(for: indexPath), !device.isThisDevice else { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            UIMenu(children: [
                UIAction(title: String(localized: "Sign Out…"), image: UIImage(systemName: "rectangle.portrait.and.arrow.right"), attributes: .destructive) { _ in
                    self?.signOut(device)
                },
            ])
        })
    }

    /// Signs `device` out: on the server's account page in Safari, or here with the password.
    private func signOut(_ device: OwnDevice) {
        Task {
            do {
                switch try await security.signOutMethod(for: device) {
                case .inBrowser(let url):
                    // the page asks to confirm; the list reloads when Lux is back in front.
                    await UIApplication.shared.open(url)
                case .withPassword:
                    askPassword(to: device)
                }
            } catch {
                show(error)
            }
        }
    }

    /// Asks for the account's password to sign `device` out, again after a wrong one.
    private func askPassword(to device: OwnDevice, after failure: (any Error)? = nil) {
        let alert = UIAlertController(
            title: String(localized: "Sign Out “\(device.title)”?"),
            message: failure?.localizedDescription
                ?? String(localized: "It will no longer be able to read your messages. Enter your account's password to sign it out."),
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.isSecureTextEntry = true
            field.textContentType = .password
            field.placeholder = String(localized: "Password")
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Sign Out"), style: .destructive) { [weak self, weak alert] _ in
            let password = alert?.textFields?.first?.text ?? ""
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await security.signOut(device, password: password)
                } catch {
                    askPassword(to: device, after: error)
                }
            }
        })
        present(alert, animated: true)
    }

    private func show(_ error: any Error) {
        let alert = UIAlertController(title: String(localized: "Could Not Sign Out"), message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        present(alert, animated: true)
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        dataSource.itemIdentifier(for: indexPath).map { !$0.isThisDevice && !$0.isVerified } ?? false
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let device = dataSource.itemIdentifier(for: indexPath) else { return }
        let verification = VerificationViewController(model: VerificationModel(session: session, kind: .device(device))) { [weak self] in
            self?.loadDevices()
        }
        navigationController?.pushViewController(verification, animated: true)
    }
}
