import LuxCore
import PhotosUI
import UIKit

/// Changes a chat's name, topic and picture for everyone in it, as far as the account may: the
/// picture from the photo library (cut to a square) or none at once, the name and topic with Save.
final class EditChatViewController: UIViewController, UICollectionViewDelegate, @MainActor PHPickerViewControllerDelegate {
    private enum Section: Int, CaseIterable { case picture, name, topic }

    private let model: ChatDetailsModel
    private let images: ImagePipeline?
    private let avatar = AvatarView()
    private let editPicture = UIButton(configuration: .plain())
    private let name = UITextField()
    private let topic = UITextView()
    private let saving = UIActivityIndicatorView(style: .medium)
    private lazy var save = UIBarButtonItem(title: String(localized: "Save"), style: .prominent, target: self, action: #selector(saveText))
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Section>!
    private var observation: AnyObject?

    init(model: ChatDetailsModel, images: ImagePipeline?) {
        self.model = model
        self.images = images
        super.init(nibName: nil, bundle: nil)
        title = model.isGroup ? String(localized: "Edit Group") : String(localized: "Edit Chat")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        navigationItem.rightBarButtonItem = save

        avatar.side = 96
        editPicture.configuration?.title = String(localized: "Edit")
        editPicture.showsMenuAsPrimaryAction = true
        name.placeholder = String(localized: "Name")
        name.text = model.row.name
        name.font = .preferredFont(forTextStyle: .body)
        name.adjustsFontForContentSizeCategory = true
        name.clearButtonMode = .whileEditing
        name.accessibilityIdentifier = "editChat.name"
        name.addAction(UIAction { [weak self] _ in self?.updateSave() }, for: .editingChanged)
        topic.text = model.topic
        topic.font = .preferredFont(forTextStyle: .body)
        topic.adjustsFontForContentSizeCategory = true
        topic.backgroundColor = .clear
        topic.isScrollEnabled = false
        topic.textContainerInset = .zero
        topic.textContainer.lineFragmentPadding = 0
        topic.accessibilityLabel = String(localized: "Topic")
        topic.delegate = self

        var layout = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        layout.headerMode = .supplementary
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: layout))
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.keyboardDismissMode = .interactive
        collectionView.delegate = self
        view.addSubview(collectionView)

        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, Section> { [weak self] cell, _, section in
            guard let self else { return }
            cell.contentConfiguration = nil
            switch section {
            case .picture:
                cell.backgroundConfiguration = .clear()
                embed(pictureHeader(), in: cell)
            case .name: embed(name, in: cell)
            case .topic: embed(topic, in: cell)
            }
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) { view, _, indexPath in
            var content = UIListContentConfiguration.header()
            content.text = switch Section(rawValue: indexPath.section) {
            case .name: String(localized: "Name")
            case .topic: String(localized: "Topic")
            default: nil
            }
            view.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, section in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: section)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Section>()
        let sections = Section.allCases.filter { section in
            switch section {
            case .picture: true
            case .name: model.canRename
            case .topic: model.canChangeTopic
            }
        }
        snapshot.appendSections(sections)
        for section in sections { snapshot.appendItems([section], toSection: section) }
        dataSource.apply(snapshot, animatingDifferences: false)

        observation = model.changes.observe { [weak self] in self?.update() }
        update()
    }

    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool { false }

    private func pictureHeader() -> UIView {
        let stack = UIStackView(arrangedSubviews: [avatar, editPicture])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 10
        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: 96),
            avatar.heightAnchor.constraint(equalToConstant: 96),
        ])
        return stack
    }

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
            cell.contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    private func update() {
        avatar.show(model.row.avatar, name: model.row.name, members: model.row.memberAvatars, images: images)
        editPicture.isHidden = !model.canChangePicture
        editPicture.isEnabled = !model.isSaving
        editPicture.menu = pictureMenu()
        if model.isSaving {
            saving.startAnimating()
            navigationItem.rightBarButtonItem = UIBarButtonItem(customView: saving)
        } else {
            saving.stopAnimating()
            navigationItem.rightBarButtonItem = save
        }
        updateSave()
    }

    private var typedName: String { (name.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    private var typedTopic: String { topic.text.trimmingCharacters(in: .whitespacesAndNewlines) }

    fileprivate func updateSave() {
        let renamed = model.canRename && !typedName.isEmpty && typedName != model.row.name
        let retopiced = model.canChangeTopic && typedTopic != (model.topic ?? "")
        save.isEnabled = !model.isSaving && (renamed || retopiced)
    }

    private func pictureMenu() -> UIMenu {
        var actions = [UIAction(title: String(localized: "Choose Photo"), image: UIImage(systemName: "photo.on.rectangle")) { [weak self] _ in
            var configuration = PHPickerConfiguration()
            configuration.filter = .images
            configuration.selectionLimit = 1
            let picker = PHPickerViewController(configuration: configuration)
            picker.delegate = self
            self?.present(picker, animated: true)
        }]
        if model.row.avatar != nil {
            actions.append(UIAction(title: String(localized: "Remove Picture"), image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                self?.change(String(localized: "The picture could not be removed.")) { try await $0.removePicture() }
            })
        }
        return UIMenu(children: actions)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider else { return }
        change(String(localized: "The picture could not be set.")) { model in
            let data = try await withCheckedThrowingContinuation { continuation in
                _ = provider.loadDataRepresentation(for: .image) { data, error in
                    if let data { continuation.resume(returning: data) } else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
                }
            }
            try await model.setPicture(data)
        }
    }

    @objc private func saveText() {
        view.endEditing(true)
        let (name, topic) = (typedName, typedTopic)
        let renamed = model.canRename && name != model.row.name
        let retopiced = model.canChangeTopic && topic != (model.topic ?? "")
        change(String(localized: "The changes could not be saved.")) { model in
            if renamed { try await model.rename(to: name) }
            if retopiced { try await model.setTopic(topic) }
        } then: { [weak self] in
            self?.dismiss(animated: true)
        }
    }

    private func change(_ title: String, _ action: @escaping (ChatDetailsModel) async throws -> Void, then done: (() -> Void)? = nil) {
        Task {
            do {
                try await action(model)
                done?()
            } catch {
                Log.app.error("chat edit: \(String(describing: error), privacy: .public)")
                let alert = UIAlertController(title: title, message: error.localizedDescription, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
                present(alert, animated: true)
            }
        }
    }
}

extension EditChatViewController: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        updateSave()
        // the row grows with the topic.
        collectionView.collectionViewLayout.invalidateLayout()
    }
}
