import LuxCore
import UIKit

/// A chat's Matrix threads, the latest active first, read back as the user scrolls: each its
/// root's sender, picture and text, how many replied and the last reply, a dot while some are
/// unread. A tap opens the thread.
final class ThreadsViewController: UIViewController, UICollectionViewDelegate {
    private let model: ThreadsModel
    private let images: ImagePipeline?
    private var observation: AnyObject?
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private var threads: [String: ListedThread] = [:]
    private let empty = UILabel()
    private let loading = UIActivityIndicatorView(style: .medium)
    /// A thread was picked: it opens over the chat.
    var onOpen: ((MatrixThread) -> Void)?

    init(model: ThreadsModel, images: ImagePipeline?) {
        self.model = model
        self.images = images
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Threads")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.largeTitleDisplayMode = .never
        let layout = UICollectionViewCompositionalLayout.list(using: UICollectionLayoutListConfiguration(appearance: .plain))
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.delegate = self
        collectionView.topEdgeEffect.style = .soft
        collectionView.accessibilityIdentifier = "threads"
        view.addSubview(collectionView)

        let images = images
        let row = UICollectionView.CellRegistration<ThreadRowCell, ListedThread> { cell, _, thread in cell.show(thread, images: images) }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { [weak self] collectionView, indexPath, id in
            guard let thread = self?.threads[id] else { return nil }
            return collectionView.dequeueConfiguredReusableCell(using: row, for: indexPath, item: thread)
        }

        empty.text = String(localized: "No threads")
        empty.textColor = .tertiaryLabel
        empty.font = .preferredFont(forTextStyle: .body)
        empty.isHidden = true
        for view in [empty, loading] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            self.view.addSubview(view)
            NSLayoutConstraint.activate([
                view.centerXAnchor.constraint(equalTo: self.view.centerXAnchor),
                view.centerYAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.centerYAnchor),
            ])
        }
        observation = model.changes.observe { [weak self] in self?.update() }
        Task { await model.loadMore() }
    }

    /// A page read back adds rows; only a thread whose replies or text changed draws again.
    private func update() {
        let old = threads
        threads = Dictionary(model.threads.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(model.threads.map(\.id))
        snapshot.reconfigureItems(threads.filter { id, thread in old[id].map { $0 != thread } ?? false }.map(\.key))
        dataSource.apply(snapshot, animatingDifferences: false)
        let none = model.threads.isEmpty
        if model.isLoading, none { loading.startAnimating() } else { loading.stopAnimating() }
        empty.isHidden = !none || model.isLoading
        if let failure = model.failure, none { empty.text = failure.localizedDescription }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath), let thread = threads[id] else { return }
        onOpen?(thread.thread)
    }

    /// Near the end: the next page.
    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard indexPath.item >= model.threads.count - 5 else { return }
        Task { await model.loadMore() }
    }
}

/// One thread of the list: the root's sender's picture, name and time over its text, then how
/// many replied and the last reply.
private final class ThreadRowCell: UICollectionViewListCell {
    private let avatar = AvatarView()
    private let name = UILabel()
    private let time = UILabel()
    private let root = UILabel()
    private let replies = UILabel()
    private let dot = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        avatar.side = 40
        name.font = .preferredFont(forTextStyle: .headline)
        name.adjustsFontForContentSizeCategory = true
        time.font = .preferredFont(forTextStyle: .footnote)
        time.textColor = .secondaryLabel
        time.adjustsFontForContentSizeCategory = true
        time.setContentCompressionResistancePriority(.required, for: .horizontal)
        root.font = .preferredFont(forTextStyle: .body)
        root.numberOfLines = 3
        root.adjustsFontForContentSizeCategory = true
        replies.font = .preferredFont(forTextStyle: .footnote)
        replies.adjustsFontForContentSizeCategory = true
        replies.lineBreakMode = .byTruncatingTail
        dot.backgroundColor = .tintColor
        dot.layer.cornerRadius = 4
        let top = UIStackView(arrangedSubviews: [name, time])
        top.spacing = 8
        let bottom = UIStackView(arrangedSubviews: [replies, dot])
        bottom.spacing = 6
        bottom.alignment = .center
        let text = UIStackView(arrangedSubviews: [top, root, bottom])
        text.axis = .vertical
        text.spacing = 3
        let all = UIStackView(arrangedSubviews: [avatar, text])
        all.spacing = 12
        all.alignment = .top
        all.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(all)
        let margins = contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: 40),
            avatar.heightAnchor.constraint(equalToConstant: 40),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            all.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            all.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            all.topAnchor.constraint(equalTo: margins.topAnchor),
            all.bottomAnchor.constraint(equalTo: margins.bottomAnchor),
        ])
        accessories = [.disclosureIndicator()]
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(_ thread: ListedThread, images: ImagePipeline?) {
        avatar.show(thread.senderAvatar, name: thread.senderName, images: images)
        name.text = thread.senderName
        time.text = TimeText.list(thread.activity)
        root.text = thread.text
        let summary = thread.summary
        let words = NSMutableAttributedString(string: summary.countText,
                                              attributes: [.font: replies.font.bold, .foregroundColor: UIColor.tintColor])
        if let latest = summary.latestReplyText {
            words.append(NSAttributedString(string: " · " + latest, attributes: [.foregroundColor: UIColor.secondaryLabel]))
        }
        replies.attributedText = words
        dot.isHidden = thread.summary.unread == 0
        accessibilityLabel = [thread.senderName, thread.text, summary.text,
                              thread.summary.unread > 0 ? String(localized: "\(thread.summary.unread) unread") : nil]
            .compactMap { $0 }.joined(separator: ", ")
    }
}
