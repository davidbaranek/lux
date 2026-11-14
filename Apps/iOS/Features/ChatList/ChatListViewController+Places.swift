import LuxCore
import UIKit

/// The places: the filter, the pinned places in the toolbar, and the sheet of all of them.
extension ChatListViewController {
    /// The places sheet: half the screen, pulled up to all of it.
    func showAllPlaces() {
        let sheet = PlacesSheetViewController(model: model, images: session.images, choose: { [weak self] place in self?.go(to: place) },
                                              pinsChanged: { [weak self] in self?.updateShortcuts() })
        placesSheet = sheet
        let navigation = UINavigationController(rootViewController: sheet)
        navigation.sheetPresentationController?.detents = [.medium(), .large()]
        navigation.sheetPresentationController?.prefersGrabberVisible = true
        present(navigation, animated: true)
    }

    /// The title names the current place; the toolbar shows the pinned places and the current one
    /// as buttons.
    func updatePlaces() {
        title = model.places.first { $0.id == model.place }?.title ?? String(localized: "Chats")
        updateShortcuts()
        updateTheme()
    }

    /// All chats, or one kind of them, and their order; the current choices are ticked.
    func filterMenuElements() -> [UIMenuElement] {
        let all = UIAction(title: String(localized: "All Chats"), image: UIImage(systemName: "tray.full"),
                           state: model.filter == nil ? .on : .off) { [weak self] _ in self?.setFilter(nil) }
        let kinds = ChatFilter.allCases.map { filter in
            UIAction(title: filter.title, image: UIImage(systemName: filter.symbol), state: model.filter == filter ? .on : .off) {
                [weak self] _ in self?.setFilter(filter)
            }
        }
        let orders = ChatOrder.allCases.map { order in
            UIAction(title: order.title, image: UIImage(systemName: order.symbol), state: model.order == order ? .on : .off) {
                [weak self] _ in self?.model.order = order
            }
        }
        return [UIMenu(options: .displayInline, children: [all]),
                UIMenu(options: .displayInline, children: Array(kinds.prefix(2))),
                UIMenu(options: .displayInline, children: Array(kinds.dropFirst(2))),
                UIMenu(title: String(localized: "Sort By"), options: .displayInline, children: orders)]
    }

    /// A filter shows as a filled button and under the title.
    private func setFilter(_ filter: ChatFilter?) {
        model.filter = filter
        // under the page's large title only: the bar's middle shows the loading bubble.
        navigationItem.largeSubtitle = filter?.title
        filterButton.image = UIImage(systemName: filter == nil ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
        filterButton.accessibilityValue = filter?.title
    }

    func go(to place: Place) {
        model.place = place
        updatePlaces()
    }

    private func updateShortcuts() {
        // the first pinned places the toolbar fits; the current one takes the last of them when it
        // is not among them, so it always shows. More would overflow into the toolbar's "…".
        let byKey = Dictionary(model.places.map { ($0.id.key, $0.id) }, uniquingKeysWith: { first, _ in first })
        var order = Array(Preferences.shared.pinnedPlaces.compactMap { byKey[$0] }.prefix(Preferences.toolbarPlaces))
        if !order.contains(model.place), model.places.contains(where: { $0.id == model.place }) {
            if order.count == Preferences.toolbarPlaces { order.removeLast() }
            order.append(model.place)
        }
        for place in order {
            guard let item = model.places.first(where: { $0.id == place }) else { continue }
            let button = shortcutItems[place] ?? makeShortcut(item)
            shortcutItems[place] = button
            button.isSelected = place == model.place
            button.accessibilityValue = item.unread > 0 ? String(localized: "\(item.unread) unread") : nil
        }
        guard order != shortcutOrder else { return }
        shortcutOrder = order
        shortcutItems = shortcutItems.filter { order.contains($0.key) }
        toolbarItems = [filterButton, .flexibleSpace()] + order.compactMap { shortcutItems[$0] } + [allPlacesButton]
            + [.flexibleSpace(), navigationItem.searchBarPlacementBarButtonItem]
    }

    private func makeShortcut(_ item: PlaceItem) -> UIBarButtonItem {
        let button = UIBarButtonItem(image: menuImage(item.icon), primaryAction: UIAction { [weak self] _ in self?.go(to: item.id) })
        button.accessibilityLabel = item.title
        button.changesSelectionAsPrimaryAction = false
        // a space shows its picture once it has loaded.
        if case .picture(let ref?) = item.icon, let images = session.images {
            let pixels = Int(28 * (view.window?.screen.scale ?? 3))
            Task { [weak button] in
                guard let picture = await images.image(ref, pixels: pixels, shape: .circle) else { return }
                button?.image = UIImage(cgImage: picture, scale: CGFloat(pixels) / 28, orientation: .up).withRenderingMode(.alwaysOriginal)
            }
        }
        return button
    }

    /// A place's icon at toolbar and menu size: a symbol, a network's logo in its own colours, or
    /// (until a space's picture loads) a symbol for a group.
    private func menuImage(_ icon: PlaceItem.Icon) -> UIImage? {
        switch icon {
        case .symbol(let name): UIImage(systemName: name)
        case .network(let network):
            NetworkImage.image(network).preparingThumbnail(of: CGSize(width: 28, height: 28))?.withRenderingMode(.alwaysOriginal)
        case .picture: UIImage(systemName: "person.3")
        }
    }
}
