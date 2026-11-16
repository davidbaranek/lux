import LuxCore
import UIKit

/// Settings: the account, its networks, the appearance (`AppearanceViewController`), encryption (the
/// key backup), privacy, search, and signing out, as an inset-grouped list.
final class SettingsViewController: UIViewController, UICollectionViewDelegate {
    private enum Section: Int, CaseIterable { case account, networks, appearance, encryption, privacy, search, session }
    private enum Item: Hashable { case profile, networks, appearance, verify, devices, recovery, readReceipts, searchIndex, searchHistory, photoLooks, photoStatus, photoAction, signOut }

    private let model: SettingsModel
    private let session: Session
    private let list: ChatListModel
    private let signOut: () -> Void
    private var observation: AnyObject?
    /// The account's picture as the profile row shows it, round; nil while it loads or without one.
    private var profilePicture: UIImage?
    private var shownPicture: ImageRef?
    private var networksObservation: AnyObject?
    /// How far back search reads, as its row shows it.
    private var shownHistory: SearchHistory?
    /// The settings' switches, made once: a cell configured again (as the model reports reading
    /// photos, many times a minute) shows the same switch, so it neither slides in anew nor loses
    /// the user's touch.
    private lazy var readReceiptsSwitch = makeSwitch { [weak self] on in self?.model.sendsReadReceipts = on }
    private lazy var photoLooksSwitch = makeSwitch { [weak self] on in Task { await self?.model.setSearchesPhotosByLook(on) } }
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
            case .appearance:
                content.text = String(localized: "Appearance")
                content.secondaryText = model.chatStyle.title
                content.image = UIImage(systemName: "paintpalette")
                cell.accessories = [.disclosureIndicator()]
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
                cell.accessories = [switchAccessory(readReceiptsSwitch, isOn: model.sendsReadReceipts)]
            case .searchIndex:
                content.text = String(localized: "Messages")
                content.secondaryText = model.searchIndex ?? String(localized: "Opening…")
                content.image = UIImage(systemName: "magnifyingglass")
            case .searchHistory:
                // the choice beside it, as Settings shows a menu's value.
                content = .valueCell()
                content.text = String(localized: "Search Back")
                content.secondaryText = model.searchHistory.title
                content.image = UIImage(systemName: "clock.arrow.circlepath")
                cell.accessories = [.popUpMenu(historyMenu, displayed: .always)]
                shownHistory = model.searchHistory
            case .photoStatus:
                content = .subtitleCell()
                content.text = String(localized: "Photos")
                content.secondaryText = model.photoStatus ?? String(localized: "Opening…")
                content.secondaryTextProperties.color = .secondaryLabel
                content.image = UIImage(systemName: "photo.on.rectangle.angled")
                if model.isPhotoWorkUnderWay {
                    let spinner = UIActivityIndicatorView(style: .medium)
                    spinner.startAnimating()
                    cell.accessories = [.customView(configuration: .init(customView: spinner, placement: .trailing()))]
                }
            case .photoLooks:
                content = .cell()
                content.text = String(localized: "Semantic Search")
                content.secondaryText = String(localized: """
                    Search always finds words. This also finds photos by what they show ("dog on the beach") and \
                    messages by what they mean ("trip to the mountains"), with a model of about 630 MB, all on this \
                    iPhone.
                    """)
                content.secondaryTextProperties.color = .secondaryLabel
                cell.accessories = [switchAccessory(photoLooksSwitch, isOn: model.searchesPhotosByLook)]
            case .photoAction:
                content = .cell()
                content.text = model.photoAction == .stop ? String(localized: "Stop Reading") : String(localized: "Read Waiting Photos Now")
                content.textProperties.color = .tintColor
            case .signOut:
                content = .cell()
                content.text = String(localized: "Sign Out")
                content.textProperties.color = .systemRed
            }
            cell.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: item)
        }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections(Section.allCases)
        snapshot.appendItems([.profile], toSection: .account)
        snapshot.appendItems([.networks], toSection: .networks)
        snapshot.appendItems([.appearance], toSection: .appearance)
        snapshot.appendItems([.verify, .devices, .recovery], toSection: .encryption)
        snapshot.appendItems([.readReceipts], toSection: .privacy)
        snapshot.appendItems(searchItems, toSection: .search)
        snapshot.appendItems([.signOut], toSection: .session)
        dataSource.apply(snapshot, animatingDifferences: false)

        observation = model.changes.observe { [weak self] in
            guard let self else { return }
            loadProfilePicture()
            var snapshot = dataSource.snapshot()
            // the action row shows only while there is something to do.
            let search = searchItems
            let shown = snapshot.itemIdentifiers(inSection: .search)
            snapshot.deleteItems(shown.filter { !search.contains($0) })
            snapshot.appendItems(search.filter { !shown.contains($0) }, toSection: .search)
            // Search Back's menu stays open while the progress beside it changes: its row is set
            // again only when its choice does (a row set again gets a new menu, closing the open one).
            var changed = shown.filter { search.contains($0) && $0 != .searchHistory }
            if shownHistory != model.searchHistory {
                shownHistory = model.searchHistory
                changed.append(.searchHistory)
            }
            snapshot.reconfigureItems([.profile, .appearance, .verify, .recovery] + changed)
            // the rows' words change in place; nothing moves, so nothing animates.
            dataSource.apply(snapshot, animatingDifferences: false)
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

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .profile?:
            guard let profile = session.profile else { return }
            navigationController?.pushViewController(ProfileViewController(model: profile, images: session.images), animated: true)
        case .networks?:
            guard let networks = session.networks else { return }
            navigationController?.pushViewController(NetworksViewController(model: networks, mode: .settings), animated: true)
        case .appearance?:
            navigationController?.pushViewController(AppearanceViewController(model: model, list: list), animated: true)
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
        case .photoAction?:
            switch model.photoAction {
            case .stop?: Task { await model.stopReadingPhotos() }
            case .readNow?: model.readPhotosNow()
            case nil: break
            }
        case .signOut?:
            confirmSignOut(from: collectionView.cellForItem(at: indexPath))
        default:
            break
        }
    }

    /// The profile row's picture, when the account's changed.
    /// How far back search reads each chat; the current choice ticked.
    private var historyMenu: UIMenu {
        UIMenu(options: .singleSelection, children: SearchHistory.allCases.map { history in
            UIAction(title: history.title, state: model.searchHistory == history ? .on : .off) { [weak self] _ in
                self?.model.searchHistory = history
            }
        })
    }

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

    /// The Search section's rows: the action only while there is one.
    private var searchItems: [Item] {
        [.searchIndex, .searchHistory, .photoLooks, .photoStatus] + (model.photoAction == nil ? [] : [.photoAction])
    }

    private func makeSwitch(_ changed: @escaping (Bool) -> Void) -> UISwitch {
        let toggle = UISwitch()
        toggle.addAction(UIAction { action in changed((action.sender as? UISwitch)?.isOn ?? false) }, for: .valueChanged)
        return toggle
    }

    /// `toggle` as a cell's trailing accessory, showing `isOn`; it moves only when that changed.
    private func switchAccessory(_ toggle: UISwitch, isOn: Bool) -> UICellAccessory {
        if toggle.isOn != isOn { toggle.setOn(isOn, animated: toggle.window != nil) }
        return .customView(configuration: .init(customView: toggle, placement: .trailing()))
    }
}
