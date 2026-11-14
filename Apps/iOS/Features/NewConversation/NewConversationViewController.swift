import LuxCore
import UIKit

/// A new conversation, in a sheet from the bottom: a search field, the chats you have with one
/// person, then people to write to (the server's directory, bridge bots, the bridges' contacts),
/// and a new room. Choosing one opens its chat, made if there is none.
final class NewConversationViewController: UIViewController, UICollectionViewDelegate, UISearchResultsUpdating {
    private enum Section: Int { case actions, chats, contacts }
    private enum Item: Hashable { case newRoom, chat(String), contact(String) }

    private let model: NewConversationModel
    private let images: ImagePipeline?
    private let open: (ChatRow) -> Void
    private let newRoom: () -> Void
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private let footer = UILabel()

    init(session: Session, open: @escaping (ChatRow) -> Void, newRoom: @escaping () -> Void) {
        model = NewConversationModel(session: session)
        images = session.images
        self.open = open
        self.newRoom = newRoom
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "New Message")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        let search = UISearchController(searchResultsController: nil)
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.hidesNavigationBarDuringPresentation = false
        // the sheet has its own close button.
        search.automaticallyShowsCancelButton = false
        search.searchBar.placeholder = String(localized: "Name, number or @user:server")
        search.searchBar.autocapitalizationType = .none
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        navigationItem.preferredSearchBarPlacement = .stacked

        var list = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        list.headerMode = .supplementary
        list.footerMode = .supplementary
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: list))
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.keyboardDismissMode = .onDrag
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "new-conversation"
        view.addSubview(collectionView)
        // what scrolls under the bar blurs out gradually, not at a hard edge (the system's default).
        collectionView.topEdgeEffect.style = .soft

        let images = images
        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            guard let self else { return }
            var content = UIListContentConfiguration.subtitleCell()
            content.secondaryTextProperties.color = .secondaryLabel
            content.imageProperties.reservedLayoutSize = CGSize(width: 40, height: 40)
            switch item {
            case .newRoom:
                content.text = String(localized: "New Room")
                content.secondaryText = String(localized: "An encrypted Matrix room")
                content.image = UIImage(systemName: "plus.bubble")
            case .chat(let id):
                guard let row = model.chats.first(where: { $0.id == id }) else { return }
                content.text = row.name
                content.secondaryText = Networks.name(row.network)
                content.image = avatarImage(row.avatar, name: row.name, images: images, item: item)
            case .contact(let id):
                guard let contact = model.contacts.first(where: { $0.id == id }) else { return }
                content.text = contact.name
                content.secondaryText = contact.name == contact.identifier
                    ? Networks.name(contact.network) : "\(Networks.name(contact.network)) · \(contact.identifier)"
                content.image = avatarImage(contact.avatar, name: contact.name, images: images, item: item)
            }
            content.imageProperties.cornerRadius = 20
            content.imageProperties.maximumSize = CGSize(width: 40, height: 40)
            cell.contentConfiguration = content
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) {
            [weak self] header, _, indexPath in
            var content = header.defaultContentConfiguration()
            content.text = switch self?.dataSource.sectionIdentifier(for: indexPath.section) {
            case .chats: String(localized: "Your Chats")
            case .contacts: String(localized: "Contacts")
            default: nil
            }
            header.contentConfiguration = content
        }
        let footerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionFooter) {
            [weak self] footer, _, indexPath in
            guard let self else { return }
            var content = footer.defaultContentConfiguration()
            if dataSource.sectionIdentifier(for: indexPath.section) == .contacts || (dataSource.snapshot().indexOfSection(.contacts) == nil
                && indexPath.section == dataSource.snapshot().numberOfSections - 1) {
                content.text = footerText
            }
            footer.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: item)
        }
        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            kind == UICollectionView.elementKindSectionHeader
                ? collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
                : collectionView.dequeueConfiguredReusableSupplementary(using: footerRegistration, for: indexPath)
        }
        model.onUpdate = { [weak self] in self?.update() }
        Task { await model.start() }
    }

    /// While contacts load, or when a part could not be searched, or when nothing is found.
    private var footerText: String? {
        if model.isSearching { return String(localized: "Searching…") }
        if let problem = model.problem { return problem }
        if model.contacts.isEmpty, !model.query.isEmpty, model.chats.isEmpty {
            return String(localized: "Nobody found. A full Matrix address (@user:server) always works.")
        }
        if model.query.isEmpty { return String(localized: "Type a name, a number or a Matrix address to find more people.") }
        return nil
    }

    private func update() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        if model.query.isEmpty {
            snapshot.appendSections([.actions])
            snapshot.appendItems([.newRoom], toSection: .actions)
        }
        if !model.chats.isEmpty {
            snapshot.appendSections([.chats])
            snapshot.appendItems(model.chats.map { .chat($0.id) }, toSection: .chats)
        }
        snapshot.appendSections([.contacts])
        snapshot.appendItems(model.contacts.map { .contact($0.id) }, toSection: .contacts)
        // reload: the rows and the footer say something new.
        dataSource.applySnapshotUsingReloadData(snapshot)
    }

    func updateSearchResults(for searchController: UISearchController) {
        model.search(searchController.searchBar.text ?? "")
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .newRoom?:
            dismiss(animated: true) { [newRoom] in newRoom() }
        case .chat(let id)?:
            guard let row = model.chats.first(where: { $0.id == id }) else { return }
            dismiss(animated: true) { [open] in open(row) }
        case .contact(let id)?:
            guard let contact = model.contacts.first(where: { $0.id == id }) else { return }
            start(contact)
        case nil:
            break
        }
    }

    /// Opens the chat with a contact, making it if there is none.
    private func start(_ contact: Contact) {
        collectionView.isUserInteractionEnabled = false
        Task {
            defer { collectionView.isUserInteractionEnabled = true }
            do {
                let roomId = try await model.start(with: contact)
                let row = ChatRow(id: roomId, name: contact.name, preview: "", date: nil, network: contact.network, avatar: contact.avatar)
                dismiss(animated: true) { [open] in open(row) }
            } catch {
                let alert = UIAlertController(title: String(localized: "Could not start the conversation"),
                                              message: error.localizedDescription, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
                present(alert, animated: true)
            }
        }
    }

    /// A picture for a row: the cached one at once; else the initials' colour circle, and the row
    /// redraws when the picture arrives.
    private func avatarImage(_ ref: ImageRef?, name: String, images: ImagePipeline?, item: Item) -> UIImage? {
        let side: CGFloat = 40, scale = traitCollection.displayScale, pixels = Int(side * scale)
        if let ref, let images {
            if let cached = images.cached(ref, pixels: pixels, shape: .circle) { return UIImage(cgImage: cached, scale: scale, orientation: .up) }
            Task { [weak self] in
                guard await images.image(ref, pixels: pixels, shape: .circle) != nil, let self else { return }
                var snapshot = dataSource.snapshot()
                guard snapshot.indexOfItem(item) != nil else { return }
                snapshot.reconfigureItems([item])
                await dataSource.apply(snapshot, animatingDifferences: false)
            }
        }
        // the initials on their colour, drawn here (a view drawn off screen may not have laid out).
        let initials = AvatarView.initials(name) as NSString
        let font = UIFont.systemFont(ofSize: side * 0.38, weight: .semibold)
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            AvatarView.color(name).setFill()
            UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: side, height: side)).fill()
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white]
            let size = initials.size(withAttributes: attributes)
            initials.draw(at: CGPoint(x: (side - size.width) / 2, y: (side - size.height) / 2), withAttributes: attributes)
        }
    }
}
