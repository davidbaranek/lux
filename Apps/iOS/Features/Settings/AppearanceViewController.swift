import LuxCore
import UIKit

/// Appearance, as the Mac's Settings has it: the colour of the places without their own (the
/// account keeps it, so every device shows it) and how chats draw their messages (on this device).
final class AppearanceViewController: UIViewController, UICollectionViewDelegate {
    private enum Section: Int, CaseIterable { case colour, messages }
    private enum Item: Hashable { case theme, chatStyle }

    private let model: SettingsModel
    private let list: ChatListModel
    /// The places' colour as chosen here: the list has it a moment later.
    private lazy var theme = list.defaultTheme
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!

    init(model: SettingsModel, list: ChatListModel) {
        self.model = model
        self.list = list
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Appearance")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        configuration.headerMode = .supplementary
        configuration.footerMode = .supplementary
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: configuration))
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.delegate = self
        view.addSubview(collectionView)
        // what scrolls under the bar blurs out gradually, not at a hard edge (the system's default).
        collectionView.topEdgeEffect.style = .soft

        let themeCell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, _ in
            guard let self else { return }
            var content = UIListContentConfiguration.valueCell()
            content.text = String(localized: "Places’ Colour")
            content.image = UIImage(systemName: "paintpalette")
            cell.contentConfiguration = content
            cell.accessories = [.customView(configuration: .init(customView: themeButton(), placement: .trailing()))]
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
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) {
            header, _, indexPath in
            var content = UIListContentConfiguration.header()
            content.text = Section(rawValue: indexPath.section) == .colour ? String(localized: "Colour") : String(localized: "Messages")
            header.contentConfiguration = content
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionFooter) {
            footer, _, indexPath in
            var content = UIListContentConfiguration.footer()
            content.text = Section(rawValue: indexPath.section) == .colour
                ? String(localized: "For places without their own colour. Touch and hold a place to give it one.")
                : String(localized: "On this iPhone.")
            footer.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            item == .theme ? collectionView.dequeueConfiguredReusableCell(using: themeCell, for: indexPath, item: item)
                : collectionView.dequeueConfiguredReusableCell(using: styleCell, for: indexPath, item: item)
        }
        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            kind == UICollectionView.elementKindSectionHeader
                ? collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
                : collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections(Section.allCases)
        snapshot.appendItems([.theme], toSection: .colour)
        snapshot.appendItems([.chatStyle], toSection: .messages)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// The rows' own controls take the taps; the rows are not selected as a whole.
    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool { false }

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
}
