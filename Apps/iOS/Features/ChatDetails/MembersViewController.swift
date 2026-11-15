import LuxCore
import UIKit

/// A group's members with their pictures and roles, the account first, found by name in the
/// search field the list scrolls with (as Contacts searches).
final class MembersViewController: UIViewController, UISearchResultsUpdating, UICollectionViewDelegate {
    private let model: MembersModel
    private let images: ImagePipeline?
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private var members: [String: ChatMember] = [:]
    private var observation: AnyObject?
    private let loading = UIActivityIndicatorView(style: .medium)
    private let empty = UILabel()

    init(model: MembersModel, images: ImagePipeline?) {
        self.model = model
        self.images = images
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Members")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        navigationItem.largeTitleDisplayMode = .never
        let search = UISearchController(searchResultsController: nil)
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = String(localized: "Search Members")
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false

        let layout = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: layout))
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.keyboardDismissMode = .onDrag
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "members"
        view.addSubview(collectionView)

        let images = images
        let cell = UICollectionView.CellRegistration<MemberCell, String> { [weak self] cell, _, id in
            guard let member = self?.members[id] else { return }
            cell.show(member, images: images)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: id)
        }
        empty.text = String(localized: "No Members Found")
        empty.font = .preferredFont(forTextStyle: .body)
        empty.textColor = .secondaryLabel
        empty.isHidden = true
        for view in [loading, empty] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            self.view.addSubview(view)
            NSLayoutConstraint.activate([
                view.centerXAnchor.constraint(equalTo: self.view.centerXAnchor),
                view.centerYAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.centerYAnchor),
            ])
        }
        loading.startAnimating()
        observation = model.changes.observe { [weak self] in self?.update() }
        Task { await model.load() }
    }

    private func update() {
        if !model.isLoading { loading.stopAnimating() }
        members = Dictionary(model.found.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(model.found.map(\.id))
        dataSource.apply(snapshot, animatingDifferences: false)
        empty.text = model.failure?.localizedDescription ?? String(localized: "No Members Found")
        empty.isHidden = model.isLoading || !model.found.isEmpty
        title = model.isLoading ? String(localized: "Members") : String(localized: "\(model.count) Members")
    }

    func updateSearchResults(for searchController: UISearchController) {
        model.search(searchController.searchBar.text ?? "")
    }

    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool { false }
}

/// A member's row: their picture, their name, and their role and id under it.
private final class MemberCell: UICollectionViewListCell {
    private let avatar = AvatarView()
    private let name = UILabel()
    private let detail = UILabel()
    private static let side: CGFloat = 36

    override init(frame: CGRect) {
        super.init(frame: frame)
        avatar.side = Self.side
        name.font = .preferredFont(forTextStyle: .body)
        detail.font = .preferredFont(forTextStyle: .footnote)
        detail.textColor = .secondaryLabel
        for label in [name, detail] { label.adjustsFontForContentSizeCategory = true }
        let lines = UIStackView(arrangedSubviews: [name, detail])
        lines.axis = .vertical
        let stack = UIStackView(arrangedSubviews: [avatar, lines])
        stack.spacing = 12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        let margins = contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: Self.side),
            avatar.heightAnchor.constraint(equalToConstant: Self.side),
            stack.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            stack.topAnchor.constraint(equalTo: margins.topAnchor),
            stack.bottomAnchor.constraint(equalTo: margins.bottomAnchor),
        ])
        // the text lines up after the picture, as the separator does.
        separatorLayoutGuide.leadingAnchor.constraint(equalTo: lines.leadingAnchor).isActive = true
        isAccessibilityElement = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(_ member: ChatMember, images: ImagePipeline?) {
        avatar.show(member.avatar, name: member.name, images: images)
        name.text = member.isOwn ? String(localized: "\(member.name) (You)") : member.name
        detail.text = [member.role.title, member.id].compactMap { $0 }.joined(separator: " · ")
        accessibilityLabel = [name.text, member.role.title].compactMap { $0 }.joined(separator: ", ")
    }
}
