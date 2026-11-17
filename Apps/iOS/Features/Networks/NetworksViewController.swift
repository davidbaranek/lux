import LuxCore
import SafariServices
import UIKit

/// The networks the account's server bridges: each with its logo, whether the account is signed
/// in there, and the way to sign in or out. In Settings it is a screen of its own; after signing
/// in it is the welcome, where the user picks the networks to bring and signs in to each in turn.
/// A server that offers none, or a bridge that does not answer, says so, and the server's admin
/// finds how to set it up behind a link.
final class NetworksViewController: UIViewController, UICollectionViewDelegate {
    enum Mode { case settings, welcome }

    private enum Item: Hashable {
        case network(NetworkOffer)
        /// The server offers none, could not be asked, or is still asked.
        case message
        case guide
    }

    private let model: NetworksModel
    private let mode: Mode
    private var picked: Set<NetworkOffer> = []
    private var observation: AnyObject?
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, Item>!
    private let connect = UIButton(configuration: .prominentGlass())
    private let later = UIButton(configuration: .plain())
    /// The welcome's sign-ins left to go, one after the other.
    private var queue: [NetworkOffer] = []
    private var spinners: [Item: UIActivityIndicatorView] = [:]

    init(model: NetworksModel, mode: Mode) {
        self.model = model
        self.mode = mode
        super.init(nibName: nil, bundle: nil)
        title = mode == .welcome ? String(localized: "Your Networks") : String(localized: "Networks")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        navigationItem.largeTitleDisplayMode = mode == .welcome ? .always : .never
        var list = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        list.headerMode = mode == .welcome ? .supplementary : .none
        list.footerMode = .supplementary
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: list))
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.delegate = self
        collectionView.topEdgeEffect.style = .soft
        view.addSubview(collectionView)

        // a cell reads its content from the model when the system asks (`setNeedsUpdateConfiguration()`):
        // a bridge's new state redraws its row, not the list.
        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            cell.configurationUpdateHandler = { [weak self] cell, _ in
                guard let cell = cell as? UICollectionViewListCell else { return }
                self?.configure(cell, item)
            }
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: item)
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) {
            header, _, _ in
            var content = UIListContentConfiguration.prominentInsetGroupedHeader()
            content.text = nil
            content.secondaryText = String(localized: "Pick the networks whose chats Lux should show. You sign in to each on its own website or with its app; your server keeps the connection.")
            content.secondaryTextProperties.font = .preferredFont(forTextStyle: .body)
            content.secondaryTextProperties.color = .secondaryLabel
            header.contentConfiguration = content
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionFooter) {
            [weak self] footer, _, _ in
            var content = UIListContentConfiguration.footer()
            content.text = self?.footerText
            footer.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            kind == UICollectionView.elementKindSectionHeader
                ? collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
                : collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }

        if mode == .welcome { addWelcomeButtons() }
        observation = model.changes.observe { [weak self] in self?.update() }
        update()
        Task { await model.load() }
    }

    // MARK: Content

    private var footerText: String? {
        switch model.offers {
        case .offered where mode == .settings:
            String(localized: "Your server's bridges connect these networks. Signing out here disconnects the network from your account, on every device.")
        default: nil
        }
    }

    /// The snapshot says which rows there are; a row's content follows the model through its
    /// configuration update, so a tick of the catching up does not rebuild the list.
    private func update() {
        var snapshot = NSDiffableDataSourceSnapshot<Int, Item>()
        snapshot.appendSections([0])
        switch model.offers {
        case .offered(let offers) where !offers.isEmpty:
            snapshot.appendItems(offers.map(Item.network))
        case .notSet:
            snapshot.appendItems([.message, .guide])
        default:
            snapshot.appendItems([.message])
        }
        if snapshot.itemIdentifiers != dataSource.snapshot().itemIdentifiers {
            dataSource.apply(snapshot, animatingDifferences: false)
        }
        for cell in collectionView.visibleCells { cell.setNeedsUpdateConfiguration() }
        updateWelcomeButtons()
    }

    private func configure(_ cell: UICollectionViewListCell, _ item: Item) {
        cell.accessories = []
        switch item {
        case .network(let offer):
            var content = UIListContentConfiguration.subtitleCell()
            content.text = offer.name
            content.secondaryTextProperties.color = .secondaryLabel
            content.image = NetworkImage.image(offer.network)
            content.imageProperties.reservedLayoutSize = CGSize(width: 32, height: 32)
            content.imageProperties.maximumSize = CGSize(width: 32, height: 32)
            content.imageToTextPadding = 14
            let status = model.statuses[offer] ?? .loading
            switch status {
            case .loading:
                content.secondaryText = String(localized: "Checking…")
                cell.accessories = [.customView(configuration: .init(customView: spinner(for: item), placement: .trailing()))]
            case .account(let account):
                if let login = account.logins.first {
                    content.secondaryText = login.state == .connected
                        ? String(localized: "Connected as \(login.name)") : "\(login.name) · \(login.state.title)"
                    if login.state.needsSignIn { content.secondaryTextProperties.color = .systemOrange }
                } else {
                    content.secondaryText = String(localized: "Not connected")
                }
                if mode == .welcome, account.logins.isEmpty {
                    cell.accessories = [.checkmark(displayed: .always, options: .init(isHidden: !picked.contains(offer)))]
                } else if account.logins.isEmpty || account.needsSignIn {
                    cell.accessories = [.label(text: String(localized: "Connect"), options: .init(tintColor: .tintColor)), .disclosureIndicator()]
                } else {
                    cell.accessories = [.disclosureIndicator()]
                }
            case .failed(let failure):
                content.secondaryText = failure.localizedDescription
                content.secondaryTextProperties.color = .systemRed
                content.secondaryTextProperties.numberOfLines = 0
                cell.accessories = [.label(text: String(localized: "Retry"), options: .init(tintColor: .tintColor))]
            }
            cell.contentConfiguration = content
        case .message:
            var content = UIListContentConfiguration.subtitleCell()
            switch model.offers {
            case .loading:
                content.text = String(localized: "Asking your server…")
                cell.accessories = [.customView(configuration: .init(customView: spinner(for: item), placement: .trailing()))]
            case .notSet(let server):
                content.image = UIImage(systemName: "network.slash")
                content.text = String(localized: "\(server) offers no networks to Lux")
                content.secondaryText = String(localized: "Its server may bridge WhatsApp, Messenger and others, but does not tell Lux where. Its admin can set that up; until then, you can still sign in to a bridge by writing to its bot.")
            case .failed(let failure):
                content.image = UIImage(systemName: "exclamationmark.triangle")
                content.text = String(localized: "Your server could not be asked")
                content.secondaryText = failure.localizedDescription
                cell.accessories = [.label(text: String(localized: "Retry"), options: .init(tintColor: .tintColor))]
            case .offered:
                content.text = String(localized: "Your server offers no networks")
            }
            content.secondaryTextProperties.color = .secondaryLabel
            content.secondaryTextProperties.numberOfLines = 0
            cell.contentConfiguration = content
        case .guide:
            var content = UIListContentConfiguration.cell()
            content.text = String(localized: "How a Server Offers Networks")
            content.textProperties.color = .tintColor
            content.image = UIImage(systemName: "book")
            cell.contentConfiguration = content
            cell.accessories = [.outlineDisclosure(options: .init(style: .cell))]
        }
    }

    /// A row's spinner, the same one each time the row is configured again: it keeps turning.
    private func spinner(for item: Item) -> UIActivityIndicatorView {
        if let spinner = spinners[item] { return spinner }
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()
        spinners[item] = spinner
        return spinner
    }

    // MARK: Taps

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .network(let offer)?:
            tapped(offer, cell: collectionView.cellForItem(at: indexPath))
        case .message?:
            if case .failed = model.offers { Task { await model.load() } }
        case .guide?:
            present(SFSafariViewController(url: BridgeSetup.guide), animated: true)
        case nil:
            break
        }
    }

    private func tapped(_ offer: NetworkOffer, cell: UIView?) {
        switch model.statuses[offer] {
        case .failed?:
            Task { await model.refresh(offer) }
        case .account(let account)? where mode == .welcome && account.logins.isEmpty:
            if !picked.insert(offer).inserted { picked.remove(offer) }
            update()
        case .account(let account)? where account.logins.isEmpty || account.needsSignIn:
            signIn(to: offer)
        case .account(let account)?:
            manage(offer, account: account, from: cell)
        default:
            break
        }
    }

    /// A connected network's choices: another login (some networks take more than one), or out.
    private func manage(_ offer: NetworkOffer, account: NetworkAccount, from cell: UIView?) {
        let sheet = UIAlertController(title: offer.name, message: nil, preferredStyle: .actionSheet)
        for login in account.logins {
            sheet.addAction(UIAlertAction(title: String(localized: "Sign Out \(login.name)"), style: .destructive) { [weak self] _ in
                self?.confirmLogOut(offer, login: login, from: cell)
            })
        }
        sheet.addAction(UIAlertAction(title: String(localized: "Add Another Login"), style: .default) { [weak self] _ in
            self?.signIn(to: offer)
        })
        sheet.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        sheet.popoverPresentationController?.sourceItem = cell
        present(sheet, animated: true)
    }

    private func confirmLogOut(_ offer: NetworkOffer, login: NetworkAccount.Login, from cell: UIView?) {
        let sheet = UIAlertController(
            title: String(localized: "Sign out of \(offer.name)?"),
            message: String(localized: "Its chats stop updating on every device. Your server's bridge may also remove them, with their history, from your chat list and merged chats; signing in again brings them back as new chats."),
            preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: String(localized: "Sign Out"), style: .destructive) { [weak self] _ in
            guard let self else { return }
            Task {
                do { try await self.model.logOut(of: offer, login: login.id) } catch { self.show(error) }
            }
        })
        sheet.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        sheet.popoverPresentationController?.sourceItem = cell
        present(sheet, animated: true)
    }

    private func signIn(to offer: NetworkOffer, then next: (() -> Void)? = nil) {
        let signIn = NetworkSignInViewController(signIn: model.signIn(to: offer)) { next?() }
        present(signIn, animated: true)
    }

    private func show(_ error: any Error) {
        let alert = UIAlertController(title: nil, message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        present(alert, animated: true)
    }

    // MARK: Welcome

    private func addWelcomeButtons() {
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        later.configuration?.title = String(localized: "Not Now")
        later.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .primaryActionTriggered)
        connect.addAction(UIAction { [weak self] _ in self?.connectPicked() }, for: .primaryActionTriggered)
        let buttons = UIStackView(arrangedSubviews: [connect, later])
        buttons.axis = .vertical
        buttons.spacing = 4
        buttons.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(buttons)
        NSLayoutConstraint.activate([
            buttons.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            connect.heightAnchor.constraint(greaterThanOrEqualToConstant: 50),
        ])
        collectionView.contentInset.bottom = 120
    }

    private func updateWelcomeButtons() {
        guard mode == .welcome else { return }
        let count = picked.count
        connect.configuration?.title = count == 0 ? String(localized: "Pick Networks to Connect")
            : String(localized: "Connect \(count) Networks")
        connect.isEnabled = count > 0
        connect.isHidden = model.offered.isEmpty
        later.configuration?.title = model.offered.isEmpty ? String(localized: "Continue") : String(localized: "Not Now")
    }

    /// Signs in to the picked networks one after the other, in the list's order.
    private func connectPicked() {
        queue = model.offered.filter(picked.contains)
        picked = []
        update()
        signInNext()
    }

    private func signInNext() {
        guard !queue.isEmpty else {
            if case .welcome = mode, !model.hasNoLogins { dismiss(animated: true) }
            return
        }
        signIn(to: queue.removeFirst()) { [weak self] in self?.signInNext() }
    }
}
