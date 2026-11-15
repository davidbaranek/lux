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
        case separate
        case leave
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
        header.onMute = { [weak self] in
            guard let self else { return }
            let setting: NotificationSetting = model.info?.notifications == .off ? .default : .off
            change(of: "chat notifications") { try await $0.setNotifications(setting) }
        }
        header.onRead = { [weak self] in
            guard let self else { return }
            let read = model.row.isUnread
            change(of: "mark read") { try await $0.markRead(read) }
        }
        navigationItem.rightBarButtonItem = model.canRename || model.canChangeTopic || model.canChangePicture
            ? UIBarButtonItem(title: String(localized: "Edit"), primaryAction: UIAction { [weak self] _ in self?.edit() })
            : nil
        navigationItem.rightBarButtonItem?.isEnabled = !model.isSaving
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.header])
        snapshot.appendItems([.header])
        if let info = model.info {
            snapshot.appendSections([.networks, .settings])
            snapshot.appendItems(info.rooms.map { .room($0.id) } + (model.canSeparate ? [.separate] : []), toSection: .networks)
            snapshot.appendItems([.notifications, .lowPriority, .messages, .encryption] + (model.mainRoom?.address == nil ? [] : [.address]), toSection: .settings)
            let groups = info.rooms.filter { !$0.isDirect }
            if !groups.isEmpty {
                snapshot.appendSections([.people])
                snapshot.appendItems(groups.map { .members($0.id) }, toSection: .people)
            }
        }
        snapshot.appendSections([.shared, .actions])
        snapshot.appendItems([.threads] + SharedKind.allCases.map(Item.shared), toSection: .shared)
        snapshot.appendItems([.leave], toSection: .actions)
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
            content.image = SettingIcon.image((model.info?.notifications ?? .default).symbol, .systemRed)
            content.text = String(localized: "Notifications")
            content.secondaryText = model.info?.notifications?.title ?? String(localized: "Mixed")
            cell.accessories = [.popUpMenu(notificationsMenu(), displayed: .always)]
        case .lowPriority:
            // the place whose rule keeps it out of the inbox, under the switch.
            content = .subtitleCell()
            content.image = SettingIcon.image("arrow.down", .systemGray)
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
            content.image = SettingIcon.image("text.bubble.fill", .systemBlue)
            content.text = String(localized: "Messages")
            content.secondaryText = model.chatStyleOverride?.title ?? String(localized: "As in Settings")
            cell.accessories = [.popUpMenu(chatStyleMenu(), displayed: .always)]
        case .encryption:
            let encrypted = model.info?.isEncrypted == true
            content.image = SettingIcon.image(encrypted ? "lock.fill" : "lock.open.fill", encrypted ? .systemGreen : .systemOrange)
            content.text = String(localized: "Encryption")
            content.secondaryText = encrypted ? String(localized: "On") : String(localized: "Off")
        case .address:
            content.image = SettingIcon.image("at", .systemTeal)
            content.text = String(localized: "Address")
            content.secondaryText = model.mainRoom?.address
            content.prefersSideBySideTextAndSecondaryText = false
        case .members(let id):
            guard let room = room(id) else { return }
            content.image = SettingIcon.image("person.2.fill", .systemPurple)
            content.text = model.row.isMerged ? Networks.name(room.network) : String(localized: "Members")
            content.secondaryText = room.joinedMembers.formatted()
            cell.accessories = [.disclosureIndicator()]
        case .threads:
            content.image = SettingIcon.image("bubble.left.and.text.bubble.right.fill", .systemIndigo)
            content.text = String(localized: "Threads")
            cell.accessories = [.disclosureIndicator()]
        case .shared(let kind):
            content.image = SettingIcon.image(kind.symbol, .systemCyan)
            content.text = kind.title
            cell.accessories = [.disclosureIndicator()]
        case .separate:
            content = .cell()
            content.image = UIImage(systemName: "arrow.triangle.branch")
            content.text = String(localized: "Separate Chats")
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
        case .members, .threads, .shared, .separate, .leave, .address: true
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
        case .separate:
            // its rooms go back to the list as their own chats: this one is gone.
            model.separate()
            navigationController?.popToRootViewController(animated: true)
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

/// A setting's symbol on a coloured tile, as Settings shows its rows.
private enum SettingIcon {
    static func image(_ symbol: String, _ color: UIColor) -> UIImage {
        let side: CGFloat = 29
        let glyph = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))?
            .withTintColor(.white, renderingMode: .alwaysOriginal)
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            color.setFill()
            UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: side, height: side), cornerRadius: 7).fill()
            guard let glyph else { return }
            let size = glyph.size
            glyph.draw(at: CGPoint(x: (side - size.width) / 2, y: (side - size.height) / 2))
        }
    }
}

/// The details' top: the chat's picture, its name, what it is (a group of how many, or its
/// networks) and its topic, on the list's background as a contact card's; under them its quick
/// actions (mute, mark read), as Messages shows them.
private final class ChatDetailsHeader: UIView {
    private let avatar = AvatarView()
    private let name = UILabel()
    private let kind = UILabel()
    private let topic = UILabel()
    private let mute = UIButton(configuration: .gray())
    private let read = UIButton(configuration: .gray())
    var onMute: (() -> Void)?
    var onRead: (() -> Void)?

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
        for (button, action) in [(mute, #selector(muteTapped)), (read, #selector(readTapped))] {
            var configuration = UIButton.Configuration.gray()
            configuration.imagePlacement = .top
            configuration.imagePadding = 4
            configuration.cornerStyle = .large
            configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)
            button.configuration = configuration
            button.addTarget(self, action: action, for: .primaryActionTriggered)
            button.widthAnchor.constraint(equalToConstant: 88).isActive = true
            button.heightAnchor.constraint(equalToConstant: 60).isActive = true
        }
        let actions = UIStackView(arrangedSubviews: [mute, read])
        actions.spacing = 10
        let stack = UIStackView(arrangedSubviews: [avatar, name, kind, topic, actions])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 4
        stack.setCustomSpacing(12, after: avatar)
        stack.setCustomSpacing(10, after: kind)
        stack.setCustomSpacing(16, after: topic)
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
        let muted = model.info?.notifications == .off
        set(mute, muted ? "bell" : "bell.slash", muted ? String(localized: "Unmute") : String(localized: "Mute"))
        mute.isEnabled = model.info != nil && !model.isSaving
        set(read, row.isUnread ? "checkmark.message" : "message.badge",
            row.isUnread ? String(localized: "Read") : String(localized: "Unread"))
        read.isEnabled = !model.isSaving
    }

    private func set(_ button: UIButton, _ symbol: String, _ title: String) {
        button.configuration?.image = UIImage(systemName: symbol)
        var text = AttributedString(title)
        text.font = .preferredFont(forTextStyle: .caption1)
        button.configuration?.attributedTitle = text
    }

    @objc private func muteTapped() { onMute?() }
    @objc private func readTapped() { onRead?() }
}
