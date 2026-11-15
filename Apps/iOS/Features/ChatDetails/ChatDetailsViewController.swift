import LuxCore
import UIKit

/// A chat's details, opened from its title, as Messages' and Contacts' cards are laid out: the
/// picture, name and topic over an inset-grouped list of its networks (a merged chat's rooms),
/// its notifications, low priority, its encryption, its members, its Matrix threads and what it
/// shared, and marking it read or leaving it. Edit (for who may) changes its name, topic and picture.
final class ChatDetailsViewController: UIViewController, UICollectionViewDelegate {
    private enum Section: Hashable { case header, networks, settings, people, shared, actions }

    private enum Item: Hashable {
        case header
        case room(String)
        case notifications, lowPriority, messages, encryption, address
        case members(String)
        case threads
        case shared(SharedKind)
        case markRead, leave
    }

    private let session: Session
    private let model: ChatDetailsModel
    private let header = ChatDetailsHeader()
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var observation: AnyObject?
    /// The chat was renamed or repictured: the thread's title follows.
    var onChange: ((ChatRow) -> Void)?
    /// A thread was picked from the chat's threads: it opens over the chat.
    var onOpenThread: ((MatrixThread) -> Void)?

    init(session: Session, row: ChatRow, list: ChatListModel?) {
        self.session = session
        model = session.details(of: row, in: list)
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Details")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        var layout = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        layout.headerMode = .supplementary
        layout.footerMode = .supplementary
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: layout))
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.delegate = self
        collectionView.topEdgeEffect.style = .soft
        collectionView.accessibilityIdentifier = "chatDetails"
        view.addSubview(collectionView)

        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            self?.configure(cell, item)
        }
        let headers = supplementary(UICollectionView.elementKindSectionHeader)
        let footers = supplementary(UICollectionView.elementKindSectionFooter)
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: item)
        }
        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: kind == UICollectionView.elementKindSectionHeader ? headers : footers,
                                                                  for: indexPath)
        }
        observation = model.changes.observe { [weak self] in self?.update() }
        update()
        Task {
            do { try await model.load() } catch { report(error, of: "chat details") }
        }
    }

    /// A section's header or footer, as `kind` says.
    private func supplementary(_ kind: String) -> UICollectionView.SupplementaryRegistration<UICollectionViewListCell> {
        UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: kind) { [weak self] view, _, indexPath in
            guard let self, let section = dataSource.sectionIdentifier(for: indexPath.section) else { return }
            let isHeader = kind == UICollectionView.elementKindSectionHeader
            var content = isHeader ? UIListContentConfiguration.header() : UIListContentConfiguration.footer()
            content.text = isHeader ? headerText(section) : footerText(section)
            view.contentConfiguration = content
        }
    }

    private func update() {
        header.show(model, images: session.images)
        navigationItem.rightBarButtonItem = model.canRename || model.canChangeTopic || model.canChangePicture
            ? UIBarButtonItem(title: String(localized: "Edit"), primaryAction: UIAction { [weak self] _ in self?.edit() })
            : nil
        navigationItem.rightBarButtonItem?.isEnabled = !model.isSaving
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.header])
        snapshot.appendItems([.header])
        if let info = model.info {
            snapshot.appendSections([.networks, .settings])
            snapshot.appendItems(info.rooms.map { .room($0.id) }, toSection: .networks)
            snapshot.appendItems([.notifications, .lowPriority, .messages, .encryption] + (model.mainRoom?.address == nil ? [] : [.address]), toSection: .settings)
            let groups = info.rooms.filter { !$0.isDirect }
            if !groups.isEmpty {
                snapshot.appendSections([.people])
                snapshot.appendItems(groups.map { .members($0.id) }, toSection: .people)
            }
        }
        snapshot.appendSections([.shared, .actions])
        snapshot.appendItems([.threads] + SharedKind.allCases.map(Item.shared), toSection: .shared)
        snapshot.appendItems([.markRead, .leave], toSection: .actions)
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
        onChange?(model.row)
    }

    private func headerText(_ section: Section) -> String? {
        switch section {
        case .networks: model.row.isMerged ? String(localized: "Networks") : String(localized: "Network")
        // a merged chat's groups by network; one group's row says it itself.
        case .people: (model.info?.rooms.filter { !$0.isDirect }.count ?? 0) > 1 ? String(localized: "Members") : nil
        case .shared: String(localized: "Shared")
        case .header, .settings, .actions: nil
        }
    }

    private func footerText(_ section: Section) -> String? {
        guard section == .settings, let info = model.info else { return nil }
        return info.isEncrypted
            ? String(localized: "Messages here are end-to-end encrypted: only the people in the chat can read them.")
            : String(localized: "Messages here are not end-to-end encrypted: the server can read them.")
    }

    private func room(_ id: String) -> RoomInfo? { model.info?.rooms.first { $0.id == id } }

    private func configure(_ cell: UICollectionViewListCell, _ item: Item) {
        var content = UIListContentConfiguration.valueCell()
        cell.accessories = []
        cell.backgroundConfiguration = nil
        switch item {
        case .header:
            cell.backgroundConfiguration = .clear()
            cell.contentConfiguration = nil
            embed(header, in: cell)
            return
        case .room(let id):
            guard let room = room(id) else { return }
            content = .subtitleCell()
            content.image = NetworkImage.image(room.network)
            content.imageProperties.maximumSize = CGSize(width: 28, height: 28)
            content.text = Networks.name(room.network)
            content.secondaryText = model.row.isMerged ? room.name : nil
            content.secondaryTextProperties.color = .secondaryLabel
        case .notifications:
            content.image = UIImage(systemName: (model.info?.notifications ?? .default).symbol)
            content.text = String(localized: "Notifications")
            content.secondaryText = model.info?.notifications?.title ?? String(localized: "Mixed")
            cell.accessories = [.popUpMenu(notificationsMenu(), displayed: .always)]
        case .lowPriority:
            // the place whose rule keeps it out of the inbox, under the switch.
            content = .subtitleCell()
            content.image = UIImage(systemName: "arrow.down.circle")
            content.text = String(localized: "Low Priority")
            content.secondaryText = model.keptOutNote
            content.secondaryTextProperties.color = .secondaryLabel
            let toggle = UISwitch()
            toggle.isOn = model.isLowPriority
            toggle.isEnabled = !model.isSaving
            toggle.accessibilityLabel = String(localized: "Low Priority")
            toggle.addAction(UIAction { [weak self, weak toggle] _ in
                guard let on = toggle?.isOn else { return }
                self?.change(of: "low priority") { try await $0.setLowPriority(on) }
            }, for: .valueChanged)
            cell.accessories = [.customView(configuration: .init(customView: toggle, placement: .trailing()))]
        case .messages:
            content.image = UIImage(systemName: "text.bubble")
            content.text = String(localized: "Messages")
            content.secondaryText = model.chatStyleOverride?.title ?? String(localized: "As in Settings")
            cell.accessories = [.popUpMenu(chatStyleMenu(), displayed: .always)]
        case .encryption:
            let encrypted = model.info?.isEncrypted == true
            content.image = UIImage(systemName: encrypted ? "lock.fill" : "lock.open")
            content.imageProperties.tintColor = encrypted ? .systemGreen : .secondaryLabel
            content.text = String(localized: "Encryption")
            content.secondaryText = encrypted ? String(localized: "On") : String(localized: "Off")
        case .address:
            content.image = UIImage(systemName: "link")
            content.text = String(localized: "Address")
            content.secondaryText = model.mainRoom?.address
            content.prefersSideBySideTextAndSecondaryText = false
        case .members(let id):
            guard let room = room(id) else { return }
            content.image = UIImage(systemName: "person.2")
            content.text = model.row.isMerged ? Networks.name(room.network) : String(localized: "Members")
            content.secondaryText = room.joinedMembers.formatted()
            cell.accessories = [.disclosureIndicator()]
        case .threads:
            content.image = UIImage(systemName: "bubble.left.and.text.bubble.right")
            content.text = String(localized: "Threads")
            cell.accessories = [.disclosureIndicator()]
        case .shared(let kind):
            content.image = UIImage(systemName: kind.symbol)
            content.text = kind.title
            cell.accessories = [.disclosureIndicator()]
        case .markRead:
            content = .cell()
            content.text = model.row.isUnread ? String(localized: "Mark as Read") : String(localized: "Mark as Unread")
            content.textProperties.color = .tintColor
        case .leave:
            content = .cell()
            content.text = model.isGroup ? String(localized: "Leave Group") : String(localized: "Leave Chat")
            content.textProperties.color = .systemRed
        }
        cell.contentConfiguration = content
    }

    private func notificationsMenu() -> UIMenu {
        NotificationMenu.choices(current: model.info?.notifications) { [weak self] setting in
            self?.change(of: "chat notifications") { try await $0.setNotifications(setting) }
        }
    }

    /// Bubbles, plain rows, or as Settings says; the current choice ticked.
    private func chatStyleMenu() -> UIMenu {
        let current = model.chatStyleOverride
        return UIMenu(options: .singleSelection, children: model.chatStyleChoices.map { choice in
            UIAction(title: choice.title, image: UIImage(systemName: choice.style == nil ? "gear" : choice.style == .plain ? "text.alignleft" : "bubble.left.and.bubble.right"),
                     state: current == choice.style ? .on : .off) { [weak self] _ in
                self?.model.chatStyleOverride = choice.style
            }
        })
    }

    /// Puts `view` in the cell's content (a reused cell keeps the one view).
    private func embed(_ view: UIView, in cell: UICollectionViewListCell) {
        guard view.superview !== cell.contentView else { return }
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(view)
        let margins = cell.contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            view.topAnchor.constraint(equalTo: margins.topAnchor),
            view.bottomAnchor.constraint(equalTo: margins.bottomAnchor),
        ])
    }

    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .members, .threads, .shared, .markRead, .leave, .address: true
        default: false
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .members(let id):
            guard let room = room(id) else { return }
            navigationController?.pushViewController(MembersViewController(model: model.members(of: room), images: session.images), animated: true)
        case .threads:
            let threads = ThreadsViewController(model: model.threads(), images: session.images)
            threads.onOpen = { [weak self] thread in self?.onOpenThread?(thread) }
            navigationController?.pushViewController(threads, animated: true)
        case .shared(let kind):
            navigationController?.pushViewController(SharedViewController(details: model, kind: kind, images: session.images), animated: true)
        case .markRead:
            let read = model.row.isUnread
            change(of: "mark read") { try await $0.markRead(read) }
        case .leave:
            confirmLeave()
        case .address:
            UIPasteboard.general.string = model.mainRoom?.address
        default:
            break
        }
    }

    private func confirmLeave() {
        let title = model.isGroup ? String(localized: "Leave \(model.row.name)?") : String(localized: "Leave the chat with \(model.row.name)?")
        let alert = UIAlertController(title: title, message: String(localized: "It goes from your chats. To come back, someone has to invite you again."),
                                      preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: String(localized: "Leave"), style: .destructive) { [weak self] _ in
            self?.change(of: "leave") { try await $0.leave() } then: { [weak self] in
                self?.navigationController?.popToRootViewController(animated: true)
            }
        })
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.popoverPresentationController?.sourceView = collectionView
        present(alert, animated: true)
    }

    private func edit() {
        let edit = EditChatViewController(model: model, images: session.images)
        present(UINavigationController(rootViewController: edit), animated: true)
    }

    /// Runs a change the user asked for; a failure is told.
    private func change(of what: String, _ action: @escaping (ChatDetailsModel) async throws -> Void, then done: (() -> Void)? = nil) {
        Task {
            do {
                try await action(model)
                done?()
            } catch {
                Log.app.error("\(what, privacy: .public): \(String(describing: error), privacy: .public)")
                let alert = UIAlertController(title: String(localized: "That did not work"), message: error.localizedDescription, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
                present(alert, animated: true)
            }
        }
    }
}

/// The details' top: the chat's picture, its name, what it is (a group of how many, or its
/// networks) and its topic, on the list's background as a contact card's.
private final class ChatDetailsHeader: UIView {
    private let avatar = AvatarView()
    private let name = UILabel()
    private let kind = UILabel()
    private let topic = UILabel()

    init() {
        super.init(frame: .zero)
        avatar.side = 96
        name.font = .preferredFont(forTextStyle: .title2).bold
        kind.font = .preferredFont(forTextStyle: .subheadline)
        kind.textColor = .secondaryLabel
        topic.font = .preferredFont(forTextStyle: .body)
        for label in [name, kind, topic] {
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
            label.textAlignment = .center
        }
        let stack = UIStackView(arrangedSubviews: [avatar, name, kind, topic])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 4
        stack.setCustomSpacing(12, after: avatar)
        stack.setCustomSpacing(10, after: kind)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: 96),
            avatar.heightAnchor.constraint(equalToConstant: 96),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(_ model: ChatDetailsModel, images: ImagePipeline?) {
        let row = model.row
        avatar.show(row.avatar, name: row.name, members: row.memberAvatars, images: images)
        name.text = row.name
        kind.text = model.subtitle
        topic.text = model.topic
        topic.isHidden = model.topic == nil
    }
}
