import LuxCore
import PhotosUI
import UIKit

/// The account's name and picture, as others see them in every chat: the picture from the photo
/// library (cut to a square in the core's upload) or none, the name as typed, saved with Save.
final class ProfileViewController: UIViewController, UICollectionViewDelegate, UITextFieldDelegate,
    @MainActor PHPickerViewControllerDelegate {
    private enum Section: Int, CaseIterable { case picture, name, userId }

    private let model: ProfileModel
    private let images: ImagePipeline?
    private let avatar = AvatarView()
    private let editPicture = UIButton(configuration: .plain())
    private let name = UITextField()
    private let saving = UIActivityIndicatorView(style: .medium)
    private lazy var save = UIBarButtonItem(title: String(localized: "Save"), style: .prominent, target: self, action: #selector(saveName))
    private var observation: AnyObject?
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Section>!

    init(model: ProfileModel, images: ImagePipeline?) {
        self.model = model
        self.images = images
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Name and Picture")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// An inset-grouped list, as Settings and Contacts draw theirs: the picture over it, the name
    /// a plain field in its row with a footer, the Matrix ID a row of its own.
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.rightBarButtonItem = save

        avatar.side = 120
        avatar.accessibilityLabel = String(localized: "Picture")
        editPicture.configuration?.title = String(localized: "Edit")
        editPicture.showsMenuAsPrimaryAction = true
        editPicture.accessibilityIdentifier = "profile.editPicture"
        name.placeholder = String(localized: "Name")
        name.font = .preferredFont(forTextStyle: .body)
        name.adjustsFontForContentSizeCategory = true
        name.autocapitalizationType = .words
        name.textContentType = .name
        name.returnKeyType = .done
        name.clearButtonMode = .whileEditing
        name.delegate = self
        name.accessibilityIdentifier = "profile.name"
        name.addAction(UIAction { [weak self] _ in self?.updateSave() }, for: .editingChanged)

        var layout = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        layout.footerMode = .supplementary
        layout.headerMode = .supplementary
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: layout))
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.keyboardDismissMode = .interactive
        collectionView.delegate = self
        collectionView.topEdgeEffect.style = .soft
        view.addSubview(collectionView)

        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, Section> { [weak self] cell, _, section in
            guard let self else { return }
            switch section {
            case .picture:
                // the picture stands on the list's background, as a contact card's does.
                cell.backgroundConfiguration = .clear()
                cell.contentConfiguration = nil
                embed(pictureHeader(), in: cell)
            case .name:
                cell.contentConfiguration = nil
                embed(name, in: cell)
            case .userId:
                var content = UIListContentConfiguration.cell()
                content.text = model.profile?.userId
                content.textProperties.color = .secondaryLabel
                cell.contentConfiguration = content
            }
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) { view, _, indexPath in
            var content = UIListContentConfiguration.header()
            content.text = Section(rawValue: indexPath.section) == .userId ? String(localized: "Matrix ID") : nil
            view.contentConfiguration = content
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionFooter) { view, _, indexPath in
            var content = UIListContentConfiguration.footer()
            content.text = Section(rawValue: indexPath.section) == .name
                ? String(localized: "People see this name and picture in your Matrix chats. Bridged networks such as WhatsApp keep their own.")
                : nil
            view.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, section in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: section)
        }
        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: kind == UICollectionView.elementKindSectionHeader ? header : footer, for: indexPath)
        }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Section>()
        snapshot.appendSections(Section.allCases)
        for section in Section.allCases { snapshot.appendItems([section], toSection: section) }
        dataSource.apply(snapshot, animatingDifferences: false)

        observation = model.changes.observe { [weak self] in self?.update() }
        update()
        Task { await model.load() }
    }

    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool { false }

    /// The picture, with Edit under it.
    private func pictureHeader() -> UIView {
        let stack = UIStackView(arrangedSubviews: [avatar, editPicture])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 4
        stack.setCustomSpacing(10, after: avatar)
        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: 120),
            avatar.heightAnchor.constraint(equalToConstant: 120),
        ])
        return stack
    }

    /// Puts `view` in the cell's content, within its margins (a reused cell keeps the one view).
    private func embed(_ view: UIView, in cell: UICollectionViewListCell) {
        guard view.superview !== cell.contentView else { return }
        view.removeFromSuperview()
        cell.contentView.subviews.forEach { $0.removeFromSuperview() }
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
        let profile = model.profile
        avatar.show(profile?.avatar, name: profile?.name ?? "", images: images)
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems([.userId])
        dataSource.apply(snapshot, animatingDifferences: false)
        // the field keeps what the user is typing; it takes the server's name only when untouched.
        if !name.isFirstResponder { name.text = profile?.displayName }
        name.isEnabled = profile?.canChangeName ?? false
        editPicture.isEnabled = (profile?.canChangeAvatar ?? false) && !model.isSaving
        editPicture.menu = pictureMenu(hasPicture: profile?.avatar != nil)
        // while a change is on its way, a spinner stands where Save is.
        if model.isSaving {
            saving.startAnimating()
            navigationItem.rightBarButtonItem = UIBarButtonItem(customView: saving)
        } else {
            saving.stopAnimating()
            navigationItem.rightBarButtonItem = save
        }
        updateSave()
    }

    private func updateSave() {
        let typed = (name.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        save.isEnabled = !model.isSaving && model.profile?.canChangeName == true && typed != (model.profile?.displayName ?? "")
    }

    private func pictureMenu(hasPicture: Bool) -> UIMenu {
        var actions = [UIAction(title: String(localized: "Choose Photo"), image: UIImage(systemName: "photo.on.rectangle")) { [weak self] _ in
            self?.pickPhoto()
        }]
        if hasPicture {
            actions.append(UIAction(title: String(localized: "Remove Picture"), image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                self?.change(String(localized: "The picture could not be removed.")) { try await $0.removePicture() }
            })
        }
        return UIMenu(children: actions)
    }

    private func pickPhoto() {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 1
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        present(picker, animated: true)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider else { return }
        change(String(localized: "The picture could not be set.")) { model in
            let data = try await Self.imageData(from: provider)
            try await model.setPicture(data)
        }
    }

    private static func imageData(from provider: NSItemProvider) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadDataRepresentation(for: .image) { data, error in
                if let data { continuation.resume(returning: data) } else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
            }
        }
    }

    @objc private func saveName() {
        name.resignFirstResponder()
        let typed = name.text ?? ""
        change(String(localized: "The name could not be saved.")) { try await $0.rename(to: typed) }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if save.isEnabled { saveName() } else { textField.resignFirstResponder() }
        return false
    }

    /// Runs a change of the profile; a failure is told, since the user asked for the change.
    private func change(_ title: String, _ action: @escaping (ProfileModel) async throws -> Void) {
        Task {
            do {
                try await action(model)
            } catch {
                Log.app.error("profile change: \(String(describing: error), privacy: .public)")
                let alert = UIAlertController(title: title, message: error.localizedDescription, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
                present(alert, animated: true)
            }
        }
    }
}
