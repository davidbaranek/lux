import LuxCore
import UIKit

/// Every place in a sheet from the bottom (the Mac's rail): the folders, then the networks and the
/// spaces, each with its unread count and the current one ticked; the pinned places in their own
/// section on top, in the bottom toolbar's order. A tap shows the place. In edit mode, as Control
/// Center's editor: − takes a place out of the pinned ones, + puts it in, and the handles drag a
/// pinned place, a network or a space to another position in its section (the networks' and
/// spaces' order the account keeps; the pinned order is this device's).
/// In edit mode the handles reorder and the pins choose which places the bottom toolbar shows.
/// A long press hides a place (the account keeps it, as the Mac's rail does) into the Hidden
/// section at the foot, or shows it again. Each row's swatch in edit mode (and the long press)
/// chooses the place's colour, which the account keeps.
final class PlacesSheetViewController: UIViewController, UICollectionViewDelegate {
    /// The pinned places, then the rail's groups, then the hidden places.
    enum Group: Hashable { case pinned, places(Place.Group), hidden }
    private static let groups: [Group] = [.pinned] + Place.Group.allCases.map(Group.places) + [.hidden]

    private let model: ChatListModel
    private let images: ImagePipeline?
    private let choose: (Place) -> Void
    private let pinsChanged: () -> Void
    private var items: [Place: PlaceItem] = [:]
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Group, Place>!
    private var observer: AnyObject?

    init(model: ChatListModel, images: ImagePipeline?, choose: @escaping (Place) -> Void, pinsChanged: @escaping () -> Void) {
        self.model = model
        self.images = images
        self.choose = choose
        self.pinsChanged = pinsChanged
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Places")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.leftBarButtonItem = editButtonItem
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        var list = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        list.headerMode = .supplementary
        list.backgroundColor = .clear
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: list))
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "places"
        view.addSubview(collectionView)
        // what scrolls under the bar blurs out gradually, not at a hard edge (the system's default).
        collectionView.topEdgeEffect.style = .soft

        let images = images
        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, Place> { [weak self] cell, _, place in
            guard let self, let item = items[place] else { return }
            var content = cell.defaultContentConfiguration()
            content.text = item.title
            if item.isHidden && !self.isPinned(place) { content.textProperties.color = .secondaryLabel }
            content.image = icon(item, images: images, reloading: place)
            content.imageProperties.maximumSize = CGSize(width: 28, height: 28)
            content.imageProperties.reservedLayoutSize = CGSize(width: 28, height: 28)
            content.imageProperties.cornerRadius = 7
            cell.contentConfiguration = content
            // a translucent fill: the rows stand out on the glass of the half sheet and on the
            // full sheet's solid background alike.
            var background = UIBackgroundConfiguration.listCell()
            background.backgroundColor = .tertiarySystemFill
            cell.backgroundConfiguration = background
            var accessories: [UICellAccessory] = []
            if place == model.place { accessories.append(.checkmark(displayed: .whenNotEditing)) }
            if item.unread > 0 { accessories.append(.label(text: "\(item.unread)", displayed: .whenNotEditing)) }
            let pinned = isPinned(place)
            if pinned {
                accessories.append(.delete(displayed: .whenEditing, actionHandler: { [weak self] in self?.setPinned(false, place) }))
            } else {
                accessories.append(.insert(displayed: .whenEditing, actionHandler: { [weak self] in self?.setPinned(true, place) }))
            }
            accessories.append(.customView(configuration: themeAccessory(item)))
            if pinned || (place.group != .folders && !item.isHidden) {
                accessories.append(.reorder(displayed: .whenEditing, options: .init(showsVerticalSeparator: false)))
            }
            cell.accessories = accessories
            cell.accessibilityValue = item.unread > 0 ? String(localized: "\(item.unread) unread") : nil
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) {
            [weak self] header, _, indexPath in
            var content = header.defaultContentConfiguration()
            content.text = switch self?.dataSource.sectionIdentifier(for: indexPath.section) {
            case .pinned: String(localized: "Pinned")
            case .places(.networks): String(localized: "Networks")
            case .places(.spaces): String(localized: "Spaces")
            case .places(.labels): String(localized: "Labels")
            case .hidden: String(localized: "Hidden")
            default: nil
            }
            header.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, place in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: place)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
        dataSource.reorderingHandlers.canReorderItem = { [weak self] place in
            guard let self else { return false }
            return isPinned(place) || (place.group != .folders && items[place]?.isHidden != true)
        }
        dataSource.reorderingHandlers.didReorder = { [weak self] _ in self?.saveOrder() }
        show(model.places)
    }

    /// The places as they are now: new unread counts reconfigure their rows; a new or gone place
    /// (or a new order from another device) rebuilds the list.
    func show(_ places: [PlaceItem]) {
        guard isViewLoaded else { return }
        let changed = places.filter { items[$0.id] != nil && items[$0.id] != $0 }.map(\.id)
        items = Dictionary(places.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var snapshot = Self.sections(places)
        let moved = snapshot.itemIdentifiers != dataSource.snapshot().itemIdentifiers
        if !moved { snapshot = dataSource.snapshot() }
        snapshot.reconfigureItems(changed.filter { snapshot.indexOfItem($0) != nil })
        // a place hidden or shown again glides to its section.
        dataSource.apply(snapshot, animatingDifferences: moved && view.window != nil)
    }

    /// The pinned places first, in the toolbar's order; the rest in their groups.
    private static func sections(_ places: [PlaceItem]) -> NSDiffableDataSourceSnapshot<Group, Place> {
        let pinnedKeys = Preferences.shared.pinnedPlaces
        let byKey = Dictionary(places.map { ($0.id.key, $0.id) }, uniquingKeysWith: { first, _ in first })
        let pinned = pinnedKeys.compactMap { byKey[$0] }
        var snapshot = NSDiffableDataSourceSnapshot<Group, Place>()
        for group in Self.groups {
            let members: [Place] = switch group {
            case .pinned: pinned
            case .places(let kind): places.filter { $0.id.group == kind && !$0.isHidden && !pinned.contains($0.id) }.map(\.id)
            case .hidden: places.filter { $0.isHidden && !pinned.contains($0.id) }.map(\.id)
            }
            guard !members.isEmpty else { continue }
            snapshot.appendSections([group])
            snapshot.appendItems(members, toSection: group)
        }
        return snapshot
    }

    private func isPinned(_ place: Place) -> Bool { Preferences.shared.pinnedPlaces.contains(place.key) }

    /// After a drag: the pinned section's order is the toolbar's; a network's or a space's new
    /// position is saved with the account, pinned ones keeping their places among them.
    private func saveOrder() {
        let snapshot = dataSource.snapshot()
        if snapshot.indexOfSection(.pinned) != nil {
            Preferences.shared.pinnedPlaces = snapshot.itemIdentifiers(inSection: .pinned).map(\.key)
            pinsChanged()
        }
        var order = model.places.map(\.id)
        for group in [Place.Group.networks, .spaces, .labels] where snapshot.indexOfSection(.places(group)) != nil {
            var moved = snapshot.itemIdentifiers(inSection: .places(group)).makeIterator()
            order = order.map { place in
                place.group == group && !isPinned(place) ? (moved.next() ?? place) : place
            }
        }
        model.reorder(order)
    }

    /// Puts a place in the pinned section (at its end) or takes it back to its group.
    private func setPinned(_ pinned: Bool, _ place: Place) {
        var keys = Preferences.shared.pinnedPlaces
        keys.removeAll { $0 == place.key }
        if pinned { keys.append(place.key) }
        Preferences.shared.pinnedPlaces = keys
        var snapshot = Self.sections(model.places)
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: true)
        pinsChanged()
    }

    /// A long press: hide the place, or show it again (not the inbox); its colour; how much of
    /// a network or a space the inbox shows.
    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard !isEditing, let place = indexPaths.first.flatMap({ dataSource.itemIdentifier(for: $0) }), place != .inbox,
              let item = items[place] else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            let action = item.isHidden
                ? UIAction(title: String(localized: "Show"), image: UIImage(systemName: "eye")) { _ in self?.model.setHidden(place, false) }
                : UIAction(title: String(localized: "Hide"), image: UIImage(systemName: "eye.slash")) { _ in self?.model.setHidden(place, true) }
            let inbox = item.inbox.map { current in
                InboxMenu.place(current: current) { rule in self?.model.setInbox(place, rule) }
            }
            return UIMenu(children: [action, self?.themeMenu(item), inbox].compactMap(\.self))
        }
    }

    /// The place's colours: its own, or the one for every place.
    private func themeMenu(_ item: PlaceItem) -> UIMenu {
        ThemeMenu.menu(title: String(localized: "Colour"), current: item.ownTheme, defaultTheme: model.defaultTheme) { [weak self] theme in
            self?.model.setTheme(item.id, theme)
        }
    }

    /// In edit mode, the place's swatch: a tap opens its colours.
    private func themeAccessory(_ item: PlaceItem) -> UICellAccessory.CustomViewConfiguration {
        var configuration = UIButton.Configuration.plain()
        configuration.image = ThemeMenu.swatch(item.ownTheme)
        configuration.preferredSymbolConfigurationForImage = .init(pointSize: 20)
        configuration.contentInsets = .init(top: 8, leading: 8, bottom: 8, trailing: 8)
        let button = UIButton(configuration: configuration)
        button.menu = themeMenu(item)
        button.showsMenuAsPrimaryAction = true
        button.accessibilityLabel = String(localized: "Colour")
        button.accessibilityValue = item.ownTheme?.title ?? String(localized: "Default")
        return .init(customView: button, placement: .trailing(displayed: .whenEditing), reservedLayoutWidth: .actual)
    }

    /// A drag stays in its group: networks among networks, spaces among spaces.
    func collectionView(_ collectionView: UICollectionView, targetIndexPathForMoveOfItemFromOriginalIndexPath original: IndexPath,
                        atCurrentIndexPath current: IndexPath, toProposedIndexPath proposed: IndexPath) -> IndexPath {
        guard proposed.section != original.section else { return proposed }
        let count = collectionView.numberOfItems(inSection: original.section)
        return IndexPath(item: proposed.section < original.section ? 0 : count - 1, section: original.section)
    }

    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)
        collectionView.isEditing = editing
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: animated)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard !isEditing, let place = dataSource.itemIdentifier(for: indexPath) else { return }
        choose(place)
        dismiss(animated: true)
    }

    /// A folder's symbol, a network's logo, or a space's picture (once loaded; until then its
    /// group symbol, and the row reconfigures when it arrives).
    private func icon(_ item: PlaceItem, images: ImagePipeline?, reloading place: Place) -> UIImage? {
        switch item.icon {
        case .symbol(let name):
            return UIImage(systemName: name)
        case .network(let network):
            return NetworkImage.image(network)
        case .picture(let ref):
            guard let ref, let images else { return UIImage(systemName: "person.3.fill") }
            let pixels = Int(28 * traitCollection.displayScale)
            if let cached = images.cached(ref, pixels: pixels) {
                return UIImage(cgImage: cached, scale: traitCollection.displayScale, orientation: .up)
            }
            Task { [weak self] in
                guard await images.image(ref, pixels: pixels) != nil, let self else { return }
                var snapshot = dataSource.snapshot()
                guard snapshot.indexOfItem(place) != nil else { return }
                snapshot.reconfigureItems([place])
                await dataSource.apply(snapshot, animatingDifferences: false)
            }
            return UIImage(systemName: "person.3.fill")
        }
    }
}
