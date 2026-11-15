import LuxCore
import UIKit

/// Settings: the account, the places' colour and how chats look, encryption (the key backup), and signing out, as an
/// inset-grouped list.
final class SettingsViewController: UIViewController, UICollectionViewDelegate {
    private enum Section: Int, CaseIterable { case account, networks, appearance, encryption, privacy, session }
    private enum Item: Hashable { case profile, networks, theme, chatStyle, verify, devices, recovery, readReceipts, searchIndex, signOut }

    private let model: SettingsModel
    private let session: Session
    private let list: ChatListModel
    /// The places' colour as chosen here: the list has it a moment later.
    private lazy var theme = list.defaultTheme
    private let signOut: () -> Void
    private var observation: AnyObject?
    /// The account's picture as the profile row shows it, round; nil while it loads or without one.
    private var profilePicture: UIImage?
    private var shownPicture: ImageRef?
    private var networksObservation: AnyObject?
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!

    init(session: Session, model: SettingsModel, list: ChatListModel, signOut: @escaping () -> Void) {
        self.session = session
        self.model = model
        self.list = list
        self.signOut = signOut
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Settings")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        collectionView = UICollectionView(frame: view.bounds,
                                          collectionViewLayout: UICollectionViewCompositionalLayout.list(using: .init(appearance: .insetGrouped)))
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.delegate = self
        view.addSubview(collectionView)
        // what scrolls under the bar blurs out gradually, not at a hard edge (the system's default).
        collectionView.topEdgeEffect.style = .soft

        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            guard let self else { return }
            var content = UIListContentConfiguration.valueCell()
            cell.accessories = []
            switch item {
            case .profile:
                content = .subtitleCell()
                content.text = model.profile?.name
                content.secondaryText = model.profile?.userId
                content.image = profilePicture ?? UIImage(systemName: "person.crop.circle.fill")
                content.imageProperties.preferredSymbolConfiguration = .init(pointSize: 40)
                content.imageProperties.maximumSize = CGSize(width: 48, height: 48)
                cell.accessories = [.disclosureIndicator()]
            case .networks:
                content.text = String(localized: "Networks")
                content.secondaryText = networksSummary
                content.image = UIImage(systemName: "point.3.connected.trianglepath.dotted")
                cell.accessories = [.disclosureIndicator()]
            case .theme:
                content.text = String(localized: "Colour")
                content.secondaryText = String(localized: "For places without their own")
                content.image = UIImage(systemName: "paintpalette")
                cell.accessories = [.customView(configuration: .init(customView: themeButton(), placement: .trailing()))]
            case .verify:
                content.text = String(localized: "Verify This Device")
                content.secondaryText = switch model.isVerified {
                case true?: String(localized: "Verified")
                case false?: String(localized: "Not verified")
                case nil: String(localized: "Checking…")
                }
                content.image = UIImage(systemName: model.isVerified == true ? "checkmark.shield" : "exclamationmark.shield")
                cell.accessories = [.disclosureIndicator()]
            case .devices:
                content.text = String(localized: "Devices")
                content.image = UIImage(systemName: "laptopcomputer.and.iphone")
                cell.accessories = [.disclosureIndicator()]
            case .recovery:
                content.text = model.recovery == .disabled ? String(localized: "Set Up Recovery") : String(localized: "Key Backup")
                content.secondaryText = model.recovery.title
                content.image = UIImage(systemName: "key")
                cell.accessories = [.disclosureIndicator()]
            case .readReceipts:
                content = .cell()
                content.text = String(localized: "Send Read Receipts")
                content.secondaryText = String(localized: "Others see when you have read their messages, on WhatsApp and Instagram too.")
                content.secondaryTextProperties.color = .secondaryLabel
                let toggle = UISwitch()
                toggle.isOn = model.sendsReadReceipts
                toggle.addAction(UIAction { [weak self, weak toggle] _ in
                    self?.model.sendsReadReceipts = toggle?.isOn ?? false
                }, for: .valueChanged)
                cell.accessories = [.customView(configuration: .init(customView: toggle, placement: .trailing()))]
            case .searchIndex:
                content.text = String(localized: "Search Index")
                content.secondaryText = model.searchIndex ?? String(localized: "Opening…")
                content.image = UIImage(systemName: "magnifyingglass")
            case .chatStyle:
                break
            case .signOut:
                content = .cell()
                content.text = String(localized: "Sign Out")
                content.textProperties.color = .systemRed
            }
            cell.contentConfiguration = content
        }
        // bubbles or plain rows, each drawn.
        let styleCell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, _ in
            guard let self else { return }
            cell.contentView.subviews.forEach { $0.removeFromSuperview() }
            let picker = ChatStylePicker(style: model.chatStyle)
            picker.onChoose = { [weak self] style in self?.model.chatStyle = style }
            picker.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.addSubview(picker)
            let margins = cell.contentView.layoutMarginsGuide
            NSLayoutConstraint.activate([
                picker.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
                picker.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
                picker.topAnchor.constraint(equalTo: margins.topAnchor, constant: 4),
                picker.bottomAnchor.constraint(equalTo: margins.bottomAnchor, constant: -4),
            ])
            cell.accessibilityElements = [picker]
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            item == .chatStyle ? collectionView.dequeueConfiguredReusableCell(using: styleCell, for: indexPath, item: item)
                : collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: item)
        }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections(Section.allCases)
        snapshot.appendItems([.profile], toSection: .account)
        snapshot.appendItems([.networks], toSection: .networks)
        snapshot.appendItems([.theme, .chatStyle], toSection: .appearance)
        snapshot.appendItems([.verify, .devices, .recovery], toSection: .encryption)
        snapshot.appendItems([.readReceipts, .searchIndex], toSection: .privacy)
        snapshot.appendItems([.signOut], toSection: .session)
        dataSource.apply(snapshot, animatingDifferences: false)

        observation = model.changes.observe { [weak self] in
            guard let self else { return }
            loadProfilePicture()
            var snapshot = dataSource.snapshot()
            snapshot.reconfigureItems([.profile, .verify, .recovery, .searchIndex])
            dataSource.apply(snapshot)
        }
        networksObservation = session.networks?.changes.observe { [weak self] in
            guard let self else { return }
            var snapshot = dataSource.snapshot()
            snapshot.reconfigureItems([.networks])
            dataSource.apply(snapshot)
        }
        Task { await session.networks?.load() }
        Task { await model.load() }
    }

    /// The style picker's tiles take the taps; its row is not selected as a whole.
    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        dataSource.itemIdentifier(for: indexPath) != .chatStyle
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .profile?:
            guard let profile = session.profile else { return }
            navigationController?.pushViewController(ProfileViewController(model: profile, images: session.images), animated: true)
        case .networks?:
            guard let networks = session.networks else { return }
            navigationController?.pushViewController(NetworksViewController(model: networks, mode: .settings), animated: true)
        case .verify?:
            let verification = VerificationViewController(model: VerificationModel(session: session)) { [weak self] in
                Task { await self?.model.load() }
            }
            navigationController?.pushViewController(verification, animated: true)
        case .devices?:
            guard let security = session.security else { return }
            navigationController?.pushViewController(DevicesViewController(session: session, security: security), animated: true)
        case .recovery? where model.recovery == .disabled:
            guard let security = session.security else { return }
            navigationController?.pushViewController(RecoverySetupViewController(security: security), animated: true)
        case .recovery?:
            navigationController?.pushViewController(RecoveryKeyViewController(model: model), animated: true)
        case .signOut?:
            confirmSignOut(from: collectionView.cellForItem(at: indexPath))
        default:
            break
        }
    }

    /// The profile row's picture, when the account's changed.
    private func loadProfilePicture() {
        let ref = model.profile?.avatar
        guard ref != shownPicture else { return }
        shownPicture = ref
        profilePicture = nil
        guard let ref, let images = session.images else { return }
        let pixels = Int(48 * traitCollection.displayScale)
        Task { [weak self] in
            guard let image = await images.image(ref, pixels: pixels, shape: .circle), let self, shownPicture == ref else { return }
            profilePicture = UIImage(cgImage: image, scale: traitCollection.displayScale, orientation: .up)
            var snapshot = dataSource.snapshot()
            snapshot.reconfigureItems([.profile])
            await dataSource.apply(snapshot)
        }
    }

    /// The colour of the places without their own, as a pop-up button of the colours.
    private func themeButton() -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.title = theme.title
        configuration.image = ThemeMenu.swatch(theme)
        configuration.imagePadding = 6
        configuration.indicator = .popup
        let button = UIButton(configuration: configuration)
        button.menu = ThemeMenu.menu(current: theme) { [weak self] theme in
            guard let self, let theme else { return }
            self.theme = theme
            list.setDefaultTheme(theme)
            var snapshot = dataSource.snapshot()
            snapshot.reconfigureItems([.theme])
            dataSource.apply(snapshot)
        }
        button.showsMenuAsPrimaryAction = true
        return button
    }

    /// How many networks are connected, or why there are none.
    private var networksSummary: String? {
        guard let networks = session.networks else { return nil }
        switch networks.offers {
        case .loading: return String(localized: "Checking…")
        case .notSet: return String(localized: "None offered")
        case .failed: return String(localized: "Not available")
        case .offered(let offers):
            let connected = offers.filter { offer in
                if case .account(let account)? = networks.statuses[offer] { !account.logins.isEmpty } else { false }
            }
            if offers.contains(where: { offer in
                if case .account(let account)? = networks.statuses[offer] { account.logins.contains { $0.state.needsSignIn } } else { false }
            }) { return String(localized: "Sign in again") }
            return String(localized: "\(connected.count) of \(offers.count) connected")
        }
    }

    private func confirmSignOut(from cell: UIView?) {
        let sheet = UIAlertController(title: String(localized: "Sign out of this iPhone?"),
                                      message: String(localized: "Without a recovery key, this device cannot read encrypted messages again."),
                                      preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: String(localized: "Sign Out"), style: .destructive) { [weak self] _ in self?.signOut() })
        sheet.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        sheet.popoverPresentationController?.sourceItem = cell
        present(sheet, animated: true)
    }
}
