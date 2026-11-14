import LuxCore
import UIKit

/// The account's devices: which are verified, and a verification for one that is not.
final class DevicesViewController: UIViewController, UICollectionViewDelegate {
    private let session: Session
    private let security: SecurityModel
    private var observation: AnyObject?
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
            content.text = String(localized: "A verified device can read your encrypted messages. Verify a device only if it is yours: you compare emojis on both.")
            view.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, device in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: device)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
        observation = security.changes.observe { [weak self] in self?.update() }
        update()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // back from a verification: the device may be verified now.
        Task { await security.loadDevices() }
    }

    private func update() {
        var snapshot = NSDiffableDataSourceSnapshot<Int, OwnDevice>()
        snapshot.appendSections([0])
        snapshot.appendItems(security.devices)
        dataSource.apply(snapshot, animatingDifferences: view.window != nil)
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        dataSource.itemIdentifier(for: indexPath).map { !$0.isThisDevice && !$0.isVerified } ?? false
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let device = dataSource.itemIdentifier(for: indexPath) else { return }
        let verification = VerificationViewController(model: VerificationModel(session: session, kind: .device(device))) { [weak self] in
            Task { await self?.security.loadDevices() }
        }
        navigationController?.pushViewController(verification, animated: true)
    }
}
