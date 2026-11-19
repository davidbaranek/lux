import LuxCore
import UIKit

/// Settings: the account, its networks, the appearance (`AppearanceViewController`), encryption (the
/// key backup), privacy, search, and signing out, as an inset-grouped list.
final class SettingsViewController: UIViewController, UICollectionViewDelegate {
    private enum Section: Int, CaseIterable { case account, networks, appearance, encryption, privacy, search, session }
    private enum Item: Hashable { case profile, networks, appearance, verify, devices, recovery, readReceipts, searchIndex, searchHistory, photoLooks, photoModel, downloadModel, photoStatus, photoAction, signOut }

    private let model: SettingsModel
    private let session: Session
    private let list: ChatListModel
    private let signOut: () -> Void
    private var observation: AnyObject?
    /// The account's picture as the profile row shows it, round; nil while it loads or without one.
    private var profilePicture: UIImage?
    private var shownPicture: ImageRef?
    private var networksObservation: AnyObject?
    /// What each row shows now: a row is set again only when what it shows changed. The model
    /// reports many times a second while search reads, and a row set again under the user's
    /// finger loses the touch (and an open menu closes).
    private var shown: [Item: Row] = [:]
    /// The settings' switches, made once: a cell configured again (as the model reports reading
    /// photos, many times a minute) shows the same switch, so it neither slides in anew nor loses
    /// the user's touch.
    private lazy var readReceiptsSwitch = makeSwitch { [weak self] on in self?.model.sendsReadReceipts = on }
    /// The photos' work under way, made once as the switches are.
    private let photoWork = UIActivityIndicatorView(style: .medium)
    /// The model's download or preparation under way.
    private let modelWork = UIActivityIndicatorView(style: .medium)
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
        // a cell whose configuration changes its height resizes by itself, in place.
        collectionView.selfSizingInvalidation = .enabled
        view.addSubview(collectionView)
        // what scrolls under the bar blurs out gradually, not at a hard edge (the system's default).
        collectionView.topEdgeEffect.style = .soft

        // each cell shows its row from the model whenever UIKit updates its configuration: as it
        // comes on screen, and when `refresh` asks it to (`setNeedsUpdateConfiguration`). A
        // configuration that changes the cell's height resizes it by itself (the collection
        // view's `selfSizingInvalidation`): no snapshot is applied for a row's words.
        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            cell.configurationUpdateHandler = { [weak self] cell, _ in
                guard let self, let cell = cell as? UICollectionViewListCell else { return }
                let row = row(item)
                shown[item] = row
                cell.contentConfiguration = content(row)
                cell.accessories = accessories(row.accessory)
            }
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
            self?.loadProfilePicture()
            self?.refresh()
        }
        networksObservation = session.networks?.changes.observe { [weak self] in self?.refresh() }
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
        case .downloadModel?:
            model.retryPhotoModel()
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
            refresh()
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

    /// The Search section's rows: the model's state under its switch while it is on, Try Again
    /// once it could not be had, and the photos' action only while there is one.
    private var searchItems: [Item] {
        [.searchIndex, .searchHistory, .photoLooks]
            + (model.photoModelStatus == nil ? [] : [.photoModel])
            + (model.canRetryPhotoModel ? [.downloadModel] : [])
            + [.photoStatus]
            + (model.photoAction == nil ? [] : [.photoAction])
    }

    private func makeSwitch(_ changed: @escaping (Bool) -> Void) -> UISwitch {
        let toggle = UISwitch()
        toggle.addAction(UIAction { action in changed((action.sender as? UISwitch)?.isOn ?? false) }, for: .valueChanged)
        return toggle
    }

    /// The rows as the model has them now: the search section's action only while there is one,
    /// and each row set again whose words, picture or control changed.
    private func refresh() {
        // which rows there are: a snapshot only when that changes (the search section's action).
        var snapshot = dataSource.snapshot()
        let search = searchItems
        let listed = snapshot.itemIdentifiers(inSection: .search)
        if listed != search {
            snapshot.deleteItems(listed.filter { !search.contains($0) })
            // each new row in its place, after the one before it (the first, the index, is always
            // there): the rows that stay keep their cells.
            for (place, item) in search.enumerated().dropFirst() where !listed.contains(item) {
                snapshot.insertItems([item], afterItem: search[place - 1])
            }
            dataSource.apply(snapshot, animatingDifferences: false)
        }
        // what they show: each visible cell whose row changed updates itself; the others do as
        // they come on screen.
        for indexPath in collectionView.indexPathsForVisibleItems {
            guard let item = dataSource.itemIdentifier(for: indexPath), shown[item] != row(item) else { continue }
            collectionView.cellForItem(at: indexPath)?.setNeedsUpdateConfiguration()
        }
    }

    /// What a row shows.
    private struct Row: Hashable {
        enum Style: Hashable { case value, subtitle, plain, profile }
        enum Tone: Hashable { case normal, action, destructive }
        enum Accessory: Hashable { case none, disclosure, readReceipts(isOn: Bool), photoLooks(isOn: Bool), historyMenu(SearchHistory), spinner, modelSpinner }
        var style = Style.value
        var text: String?
        var detail: String?
        var symbol: String?
        var picture: UIImage?
        var tone = Tone.normal
        var accessory = Accessory.none
    }

    private func row(_ item: Item) -> Row {
        switch item {
        case .profile:
            Row(style: .profile, text: model.profile?.name, detail: model.profile?.userId, symbol: "person.crop.circle.fill",
                picture: profilePicture, accessory: .disclosure)
        case .networks:
            Row(text: String(localized: "Networks"), detail: networksSummary, symbol: "point.3.connected.trianglepath.dotted",
                accessory: .disclosure)
        case .appearance:
            Row(text: String(localized: "Appearance"), detail: model.chatStyle.title, symbol: "paintpalette", accessory: .disclosure)
        case .verify:
            Row(text: String(localized: "Verify This Device"), detail: verification,
                symbol: model.isVerified == true ? "checkmark.shield" : "exclamationmark.shield", accessory: .disclosure)
        case .devices:
            Row(text: String(localized: "Devices"), symbol: "laptopcomputer.and.iphone", accessory: .disclosure)
        case .recovery:
            Row(text: model.recovery == .disabled ? String(localized: "Set Up Recovery") : String(localized: "Key Backup"),
                detail: model.recovery.title, symbol: "key", accessory: .disclosure)
        case .readReceipts:
            Row(style: .plain, text: String(localized: "Send Read Receipts"),
                detail: String(localized: "Others see when you have read their messages, on WhatsApp and Instagram too."),
                accessory: .readReceipts(isOn: model.sendsReadReceipts))
        case .searchIndex:
            // under its title, as the photos' status: a value beside it would wrap, and its row
            // grow and shrink, as the count changes.
            Row(style: .subtitle, text: String(localized: "Messages"), detail: model.searchIndex ?? String(localized: "Opening…"),
                symbol: "magnifyingglass")
        case .searchHistory:
            // the choice beside it, as Settings shows a menu's value.
            Row(text: String(localized: "Search Back"), detail: model.searchHistory.title, symbol: "clock.arrow.circlepath",
                accessory: .historyMenu(model.searchHistory))
        case .photoStatus:
            Row(style: .subtitle, text: String(localized: "Photos"), detail: model.photoStatus ?? String(localized: "Opening…"),
                symbol: "photo.on.rectangle.angled", accessory: model.isPhotoWorkUnderWay ? .spinner : .none)
        case .photoLooks:
            Row(style: .plain, text: String(localized: "Semantic Search"),
                detail: String(localized: """
                    Search always finds words. This also finds photos by what they show ("dog on the beach") and \
                    messages by what they mean ("trip to the mountains"), with a model of about 650 MB, all on this \
                    iPhone.
                    """),
                accessory: .photoLooks(isOn: model.searchesPhotosByLook))
        case .photoModel:
            Row(style: .subtitle, text: String(localized: "Model"), detail: model.photoModelStatus, symbol: "cpu",
                accessory: model.isPhotoModelUnderWay ? .modelSpinner : .none)
        case .downloadModel:
            Row(style: .plain, text: String(localized: "Try Again"), tone: .action)
        case .photoAction:
            Row(style: .plain,
                text: model.photoAction == .stop ? String(localized: "Stop Reading") : String(localized: "Read Waiting Photos Now"),
                tone: .action)
        case .signOut:
            Row(style: .plain, text: String(localized: "Sign Out"), tone: .destructive)
        }
    }

    /// Whether this device is verified, in words.
    private var verification: String {
        switch model.isVerified {
        case true?: String(localized: "Verified")
        case false?: String(localized: "Not verified")
        case nil: String(localized: "Checking…")
        }
    }

    private func content(_ row: Row) -> UIListContentConfiguration {
        var content: UIListContentConfiguration = switch row.style {
        case .value: .valueCell()
        case .subtitle, .profile: .subtitleCell()
        case .plain: .cell()
        }
        content.text = row.text
        content.secondaryText = row.detail
        content.image = row.picture ?? row.symbol.flatMap { UIImage(systemName: $0) }
        switch row.style {
        case .profile:
            content.imageProperties.preferredSymbolConfiguration = .init(pointSize: 40)
            content.imageProperties.maximumSize = CGSize(width: 48, height: 48)
        case .subtitle, .plain:
            content.secondaryTextProperties.color = .secondaryLabel
        case .value:
            break
        }
        switch row.tone {
        case .normal: break
        case .action: content.textProperties.color = .tintColor
        case .destructive: content.textProperties.color = .systemRed
        }
        return content
    }

    private func accessories(_ accessory: Row.Accessory) -> [UICellAccessory] {
        switch accessory {
        case .none:
            return []
        case .disclosure:
            return [.disclosureIndicator()]
        case .readReceipts(let isOn):
            return [switchAccessory(readReceiptsSwitch, isOn: isOn)]
        case .photoLooks(let isOn):
            return [switchAccessory(photoLooksSwitch, isOn: isOn)]
        case .historyMenu:
            return [.popUpMenu(historyMenu, displayed: .always)]
        case .spinner:
            // the same spinner each time: one made anew would start its turn over at each update.
            photoWork.startAnimating()
            return [.customView(configuration: .init(customView: photoWork, placement: .trailing()))]
        case .modelSpinner:
            modelWork.startAnimating()
            return [.customView(configuration: .init(customView: modelWork, placement: .trailing()))]
        }
    }

    /// `toggle` as a cell's trailing accessory, showing `isOn`; it moves only when that changed.
    private func switchAccessory(_ toggle: UISwitch, isOn: Bool) -> UICellAccessory {
        if toggle.isOn != isOn { toggle.setOn(isOn, animated: toggle.window != nil) }
        return .customView(configuration: .init(customView: toggle, placement: .trailing()))
    }
}
