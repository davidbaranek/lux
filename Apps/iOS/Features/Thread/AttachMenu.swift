import LuxCore
import Photos
import UIKit
import VisionKit

/// What the attach panel's buttons offer, in their order: the library's photos beyond the newest,
/// files and a scan. The camera is the first tile of the photos' row.
enum AttachChoice: CaseIterable {
    case camera, photos, files, scan

    var title: String {
        switch self {
        case .camera: String(localized: "Camera")
        case .photos: String(localized: "Photos")
        case .files: String(localized: "Files")
        case .scan: String(localized: "Scan")
        }
    }

    var symbol: String {
        switch self {
        case .camera: "camera.fill"
        case .photos: "photo.on.rectangle"
        case .files: "doc"
        case .scan: "doc.viewfinder"
        }
    }

    /// The camera and the scanner need a camera (not in the Simulator).
    @MainActor var isAvailable: Bool {
        switch self {
        case .camera: UIImagePickerController.isSourceTypeAvailable(.camera)
        case .scan: VNDocumentCameraViewController.isSupported
        case .photos, .files: true
        }
    }
}

/// What the composer's + opens in the keyboard's place: the camera
/// and the library's newest photos and videos in a row, and buttons for all photos, files and a
/// scan. A tap on a photo puts it in the composer at once, numbered in the order picked; another
/// tap takes it out. Without the library's permission the row is left out.
final class AttachPanel: UIInputView, UICollectionViewDelegate, UICollectionViewDataSourcePrefetching, PHPhotoLibraryChangeObserver {
    enum Tile: Hashable {
        case camera
        case photo(String)
        /// With limited access: the system's sheet to share other photos with Lux.
        case more
    }

    var onToggle: ((PHAsset) -> Void)?
    var onChoice: ((AttachChoice) -> Void)?
    var onManage: (() -> Void)?
    /// The photos in the composer, in their order: their tiles show their number.
    var picked: [String] = [] {
        didSet {
            guard picked != oldValue else { return }
            for cell in collectionView.visibleCells { cell.setNeedsUpdateConfiguration() }
        }
    }
    private let access: RecentPhotos.Access
    /// The camera's tile comes first where there is a camera; the photos follow it.
    private let firstPhoto = AttachChoice.camera.isAvailable ? 1 : 0
    private var assets = PHFetchResult<PHAsset>()
    /// Decodes the pictures at the tiles' size, off the main thread, and ahead of the scroll.
    private let images = PHCachingImageManager()
    private var thumbnail = CGSize.zero
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: Self.layout())
    private lazy var dataSource: UICollectionViewDiffableDataSource<Int, Tile> = {
        let photo = UICollectionView.CellRegistration<RecentPhotoCell, Tile> { [weak self] cell, path, tile in
            guard let self, case .photo(let id) = tile, let asset = asset(at: path) else { return }
            cell.order = { [weak self] in self?.picked.firstIndex(of: id).map { $0 + 1 } }
            cell.show(asset, images: images, size: thumbnail)
        }
        let symbol = UICollectionView.CellRegistration<SymbolTileCell, Tile> { cell, _, tile in
            switch tile {
            case .camera: cell.show(symbol: AttachChoice.camera.symbol, title: AttachChoice.camera.title)
            default: cell.show(symbol: "plus", title: String(localized: "More Photos"))
            }
        }
        return UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, path, tile in
            if case .photo = tile { return collectionView.dequeueConfiguredReusableCell(using: photo, for: path, item: tile) }
            return collectionView.dequeueConfiguredReusableCell(using: symbol, for: path, item: tile)
        }
    }()

    /// The row's tiles and the buttons' height.
    private static let tile: CGFloat = 120
    private static let buttonHeight: CGFloat = 80

    /// `height` tall, the keyboard's (with the home indicator's band): the row and the buttons
    /// in its middle; only the buttons without the library.
    init(access: RecentPhotos.Access, height: CGFloat) {
        self.access = access
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: height), inputViewStyle: .keyboard)
        let buttons = UIStackView(arrangedSubviews: AttachChoice.allCases.filter { $0 != .camera && $0.isAvailable }.map(button))
        buttons.distribution = .fillEqually
        buttons.spacing = 10
        buttons.isLayoutMarginsRelativeArrangement = true
        buttons.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
        buttons.heightAnchor.constraint(equalToConstant: Self.buttonHeight).isActive = true
        let content = UIStackView(arrangedSubviews: [buttons])
        content.axis = .vertical
        content.spacing = 14
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            content.centerYAnchor.constraint(equalTo: safeAreaLayoutGuide.centerYAnchor),
        ])
        guard access != .picker else { return }
        collectionView.backgroundColor = .clear
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        collectionView.accessibilityIdentifier = "recent photos"
        collectionView.heightAnchor.constraint(equalToConstant: Self.tile).isActive = true
        content.insertArrangedSubview(collectionView, at: 0)
        PHPhotoLibrary.shared().register(self)
        assets = RecentPhotos.fetch()
        showTiles()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    isolated deinit { PHPhotoLibrary.shared().unregisterChangeObserver(self) }

    /// A large glass button, its symbol over its title.
    private func button(_ choice: AttachChoice) -> UIButton {
        var configuration = UIButton.Configuration.glass()
        configuration.image = UIImage(systemName: choice.symbol, withConfiguration: UIImage.SymbolConfiguration(textStyle: .title2))
        configuration.imagePlacement = .top
        configuration.imagePadding = 6
        configuration.title = choice.title
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = .preferredFont(forTextStyle: .footnote)
            return attributes
        }
        configuration.cornerStyle = .large
        return UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in self?.onChoice?(choice) })
    }

    private static func layout() -> UICollectionViewCompositionalLayout {
        // square tiles as tall as the row, side by side, scrolling sideways.
        let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .fractionalHeight(1)))
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalHeight(1), heightDimension: .fractionalHeight(1)), subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = 8
        section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
        let configuration = UICollectionViewCompositionalLayoutConfiguration()
        configuration.scrollDirection = .horizontal
        return UICollectionViewCompositionalLayout(section: section, configuration: configuration)
    }

    override func layoutSubviews() {
        // a tile decoded at the screen's pixels, known before the row lays out its first tiles.
        let side = Self.tile * traitCollection.displayScale
        if side != thumbnail.width {
            images.stopCachingImagesForAllAssets()
            thumbnail = CGSize(width: side, height: side)
        }
        super.layoutSubviews()
    }

    /// The camera, the newest photos, and More with limited access: photos come and go.
    private func showTiles() {
        var tiles: [Tile] = firstPhoto == 1 ? [.camera] : []
        tiles += assets.objects(at: IndexSet(integersIn: 0..<assets.count)).map { .photo($0.localIdentifier) }
        if access == .grid(limited: true) { tiles.append(.more) }
        var snapshot = NSDiffableDataSourceSnapshot<Int, Tile>()
        snapshot.appendSections([0])
        snapshot.appendItems(tiles)
        dataSource.apply(snapshot, animatingDifferences: window != nil)
    }

    /// Photos added, removed or moved change the row; a photo edited is shown again in place.
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in
            guard let self, let details = changeInstance.changeDetails(for: assets) else { return }
            assets = details.fetchResultAfterChanges
            if !details.hasIncrementalChanges || details.insertedIndexes != nil || details.removedIndexes != nil || details.hasMoves {
                showTiles()
            } else if !details.changedObjects.isEmpty {
                var snapshot = dataSource.snapshot()
                snapshot.reconfigureItems(details.changedObjects.map { .photo($0.localIdentifier) })
                dataSource.apply(snapshot, animatingDifferences: false)
            }
        }
    }

    private func asset(at path: IndexPath) -> PHAsset? {
        guard case .photo = dataSource.itemIdentifier(for: path) else { return nil }
        let index = path.item - firstPhoto
        return index >= 0 && index < assets.count ? assets.object(at: index) : nil
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .camera: onChoice?(.camera)
        case .more: onManage?()
        case .photo: if let asset = asset(at: indexPath) { onToggle?(asset) }
        case nil: break
        }
    }

    // MARK: Decoding ahead

    private func assets(at paths: [IndexPath]) -> [PHAsset] {
        paths.compactMap(asset(at:))
    }

    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        images.startCachingImages(for: assets(at: indexPaths), targetSize: thumbnail, contentMode: .aspectFill,
                                  options: RecentPhotoCell.options)
    }

    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        images.stopCachingImages(for: assets(at: indexPaths), targetSize: thumbnail, contentMode: .aspectFill,
                                 options: RecentPhotoCell.options)
    }
}

/// A photo or a video of the row: its picture, a video's length, and a ring that shows its number
/// while it is in the composer.
private final class RecentPhotoCell: UICollectionViewCell {
    static let options: PHImageRequestOptions = {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        return options
    }()
    /// Its place among the photos in the composer, from 1; nil while it is not in it.
    var order: () -> Int? = { nil }
    private let picture = UIImageView()
    private let length = UILabel()
    private let badge = UIImageView()
    private var request: PHImageRequestID?
    private weak var images: PHImageManager?
    private var assetId: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.layer.cornerRadius = 18
        contentView.layer.cornerCurve = .continuous
        contentView.clipsToBounds = true
        picture.contentMode = .scaleAspectFill
        picture.backgroundColor = .tertiarySystemFill
        length.font = .preferredFont(forTextStyle: .caption1).bold
        length.textColor = .white
        length.shadowColor = .black.withAlphaComponent(0.5)
        length.shadowOffset = CGSize(width: 0, height: 1)
        badge.layer.shadowOpacity = 0.3
        badge.layer.shadowRadius = 2
        badge.layer.shadowOffset = .zero
        for view in [picture, length, badge] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        NSLayoutConstraint.activate([
            picture.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            picture.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            picture.topAnchor.constraint(equalTo: contentView.topAnchor),
            picture.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            length.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
            length.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            badge.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            badge.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            badge.widthAnchor.constraint(equalToConstant: 26),
            badge.heightAnchor.constraint(equalToConstant: 26),
        ])
        isAccessibilityElement = true
        configurationUpdateHandler = { cell, _ in
            guard let cell = cell as? RecentPhotoCell else { return }
            let order = cell.order()
            // a numbered disc in the tint while it is in the composer, an empty ring while not.
            cell.badge.image = UIImage(systemName: order.map { "\($0).circle.fill" } ?? "circle")
            cell.badge.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
                paletteColors: order == nil ? [.white] : [.white, .tintColor])
            cell.picture.alpha = order == nil ? 1 : 0.8
            cell.accessibilityTraits = order == nil ? [.image, .button] : [.image, .button, .selected]
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        if let request { images?.cancelImageRequest(request) }
        request = nil
        picture.image = nil
    }

    func show(_ asset: PHAsset, images: PHImageManager, size: CGSize) {
        self.images = images
        assetId = asset.localIdentifier
        let id = asset.localIdentifier
        let isVideo = asset.mediaType == .video
        length.text = isVideo ? Duration.seconds(asset.duration).formatted(.time(pattern: .minuteSecond)) : nil
        accessibilityLabel = isVideo ? String(localized: "Video, \(length.text ?? "")") : String(localized: "Photo")
        if let date = asset.creationDate { accessibilityValue = date.formatted(date: .abbreviated, time: .shortened) }
        setNeedsUpdateConfiguration()
        // Photos decodes it at the tile's size, off the main thread, and hands it here on it.
        request = images.requestImage(for: asset, targetSize: size, contentMode: .aspectFill, options: Self.options) { [weak self] image, _ in
            MainActor.assumeIsolated {
                guard let self, self.assetId == id else { return }
                self.picture.image = image
            }
        }
    }
}

/// A tile of the row that is not a photo: the camera, or More Photos with limited access; its
/// symbol over its title.
private final class SymbolTileCell: UICollectionViewCell {
    private let symbol = UIImageView()
    private let title = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        symbol.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .title1)
        symbol.tintColor = .label
        title.font = .preferredFont(forTextStyle: .footnote)
        title.adjustsFontForContentSizeCategory = true
        let stack = UIStackView(arrangedSubviews: [symbol, title])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
        var background = UIBackgroundConfiguration.clear()
        background.backgroundColor = .tertiarySystemFill
        background.cornerRadius = 18
        backgroundConfiguration = background
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(symbol name: String, title text: String) {
        symbol.image = UIImage(systemName: name)
        title.text = text
        accessibilityLabel = text
    }
}
