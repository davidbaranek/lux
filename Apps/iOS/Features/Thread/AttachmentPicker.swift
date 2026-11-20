import LuxCore
import PDFKit
import Photos
import PhotosUI
import UIKit
import UniformTypeIdentifiers
import VisionKit

/// The composer's + : a panel in the keyboard's place (`AttachPanel`) with the camera, the newest
/// photos, all photos, files and a document scan; or what is pasted or dropped. The newest photos
/// need the library's permission, asked the first time the panel opens; without it the panel has
/// only its buttons, and Photos is the system's picker, which needs none (it runs out of process
/// and hands over only what is chosen).
@MainActor
final class AttachmentPicker: NSObject, @MainActor PHPickerViewControllerDelegate, @MainActor UIDocumentPickerDelegate,
    @MainActor UIDropInteractionDelegate,
    @MainActor UIImagePickerControllerDelegate, @MainActor UINavigationControllerDelegate,
    @MainActor VNDocumentCameraViewControllerDelegate {
    private weak var host: UIViewController?
    private let picked: ([URL]) -> Void
    /// A file put in the composer at once, before `write` has written it.
    private let arriving: (URL, _ write: @escaping @MainActor (_ progress: @escaping @Sendable (Double) -> Void) async throws -> Void) -> Void
    private let removed: (URL) -> Void
    private weak var panel: AttachPanel?
    private weak var composer: ComposerView?
    /// The newest photos picked in the panel, in order, and each one's file once written.
    private var selection = RecentPhotoSelection()
    private var written: [String: URL] = [:]
    /// Files handed to the composer that it has not listed yet.
    private var handed: Set<URL> = []
    /// Copying the picked photos out of the picker: it ends with the screen.
    private let copying = TaskBag()
    private var copies: URL { FileManager.default.temporaryDirectory.appendingPathComponent("picked", isDirectory: true) }
    /// The library's permission, asked the first time the panel opens.
    var libraryAccess: @MainActor () async -> PHAuthorizationStatus = {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return status == .notDetermined ? await PHPhotoLibrary.requestAuthorization(for: .readWrite) : status
    }

    init(host: UIViewController, picked: @escaping ([URL]) -> Void,
         arriving: @escaping (URL, _ write: @escaping @MainActor (_ progress: @escaping @Sendable (Double) -> Void) async throws -> Void) -> Void,
         removed: @escaping (URL) -> Void) {
        self.host = host
        self.picked = picked
        self.arriving = arriving
        self.removed = removed
    }

    // MARK: The panel

    /// The + : opens the panel in the keyboard's place, as tall as the keyboard; the × gives the
    /// keyboard back.
    func togglePanel(in composer: ComposerView) {
        guard composer.inputPanel == nil else { return composer.closePanel() }
        copying.run("library access") { [weak self, weak composer] in
            guard let status = await self?.libraryAccess(), let self, let composer else { return }
            let panel = AttachPanel(access: RecentPhotos.Access(status), height: ComposerView.keyboardHeight)
            panel.picked = selection.ids
            panel.onToggle = { [weak self] asset in self?.toggle(asset) }
            panel.onChoice = { [weak self] choice in self?.choose(choice) }
            panel.onManage = { [weak self] in
                guard let host = self?.host else { return }
                PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: host)
            }
            self.panel = panel
            self.composer = composer
            composer.inputPanel = panel
        }
    }

    private func choose(_ choice: AttachChoice) {
        switch choice {
        case .camera: takePhoto()
        case .photos: pickPhotos()
        case .files: pickFiles()
        case .scan: scan()
        }
    }

    /// A photo of the panel goes into the composer, or comes out of it.
    private func toggle(_ asset: PHAsset) {
        let id = asset.localIdentifier
        guard selection.toggle(id) else { return }
        panel?.picked = selection.ids
        if !selection.ids.contains(id) {
            // taken out while it is still coming: its download stops.
            if let file = written.removeValue(forKey: id) { removed(file) }
            return
        }
        guard let file = RecentPhotos.destination(of: asset, in: copies) else {
            selection.toggle(id)
            panel?.picked = selection.ids
            return
        }
        // in the composer at once, in the order picked, with the library's picture of it; the
        // file follows (from iCloud if it is only there), and sending waits for it.
        written[id] = file
        handed.insert(file)
        arriving(file) { progress in try await RecentPhotos.write(asset, to: file, progress: progress) }
        let side = AttachmentStrip.side * (composer?.traitCollection.displayScale ?? 3)
        PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: side, height: side), contentMode: .aspectFill,
                                              options: Self.previewOptions) { [weak self] image, _ in
            MainActor.assumeIsolated {
                guard let image else { return }
                self?.composer?.showPreview(image, of: file)
            }
        }
    }

    /// A picked photo's picture in the composer, decoded off the main thread at the tile's size.
    private static let previewOptions: PHImageRequestOptions = {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        return options
    }()

    /// The composer's files changed: a photo taken out there or sent is no longer picked here.
    func pendingChanged(_ files: [URL]) {
        let pending = Set(files)
        handed.subtract(pending)
        for (id, file) in written where !pending.contains(file) && !handed.contains(file) {
            written[id] = nil
            selection.toggle(id)
        }
        panel?.picked = selection.ids
    }

    // MARK: All Photos and Files

    private func pickPhotos() {
        var configuration = PHPickerConfiguration()
        configuration.selectionLimit = RecentPhotos.selectionLimit
        configuration.filter = .any(of: [.images, .videos])
        // the original files as they are (HEIC, MOV): AttachmentMaker makes them ready.
        configuration.preferredAssetRepresentationMode = .current
        configuration.selection = .ordered
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        host?.present(picker, animated: true)
    }

    private func pickFiles() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = self
        host?.present(picker, animated: true)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        copy(results.compactMap { result in
            let provider = result.itemProvider
            return [UTType.movie, .image].first { provider.hasItemConformingToTypeIdentifier($0.identifier) }.map { (provider, $0, nil) }
        })
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        picked(urls)
    }

    // MARK: Camera

    private func takePhoto() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else { return }
        let camera = UIImagePickerController()
        camera.sourceType = .camera
        camera.mediaTypes = [UTType.image.identifier, UTType.movie.identifier]
        camera.delegate = self
        host?.present(camera, animated: true)
    }

    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        picker.dismiss(animated: true)
        let copies = copies
        if let video = info[.mediaURL] as? URL {
            copying.run { [weak self] in
                let files = try await PastedItems.files([.file(video)], in: copies)
                self?.picked(files)
            }
        } else if let photo = info[.originalImage] as? UIImage {
            copying.run { [weak self] in
                let file = try await Self.write(photo, in: copies)
                self?.picked([file])
            }
        }
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
    }

    /// A photo the camera took, as a JPEG file (AttachmentMaker sizes it to send), off the main thread.
    @concurrent
    private nonisolated static func write(_ photo: UIImage, in directory: URL) async throws -> URL {
        guard let data = photo.jpegData(compressionQuality: 0.9),
              let file = try await PastedItems.files([.data(data, type: .jpeg, name: String(localized: "Photo"))], in: directory).first
        else { throw CocoaError(.fileWriteUnknown) }
        return file
    }

    // MARK: Scan

    private func scan() {
        guard VNDocumentCameraViewController.isSupported else { return }
        let camera = VNDocumentCameraViewController()
        camera.delegate = self
        host?.present(camera, animated: true)
    }

    func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
        let pages = (0..<scan.pageCount).map(scan.imageOfPage(at:))
        let title = scan.title
        controller.dismiss(animated: true)
        let copies = copies
        copying.run { [weak self] in
            let file = try await Self.pdf(of: pages, named: title, in: copies)
            self?.picked([file])
        }
    }

    func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
        controller.dismiss(animated: true)
    }

    func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: any Error) {
        controller.dismiss(animated: true)
        Log.app.error("scan: \(String(describing: error), privacy: .public)")
    }

    /// The scanned pages as one PDF, each an A4 page's width and as tall as its page, off the main
    /// thread (the pages are photos the camera's size).
    @concurrent
    private nonisolated static func pdf(of pages: [UIImage], named title: String, in directory: URL) async throws -> URL {
        let document = PDFDocument()
        for (index, image) in pages.enumerated() where image.size.width > 0 {
            let width: CGFloat = 595
            let box = CGRect(x: 0, y: 0, width: width, height: width * image.size.height / image.size.width)
            guard let page = PDFPage(image: image, options: [.mediaBox: box, .compressionQuality: 0.7]) else { continue }
            document.insert(page, at: index)
        }
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(PastedItems.fileName(title, type: .pdf))
        guard document.pageCount > 0, document.write(to: file) else { throw CocoaError(.fileWriteUnknown) }
        return file
    }

    // MARK: Pasted or dropped

    /// Photos, videos and files pasted into the composer or dropped on the chat: they wait in it as
    /// picked ones do. Text among them is not theirs (the text view pastes it).
    func take(_ providers: [NSItemProvider]) {
        // a screenshot has no name: it is named for what it is ("Pasted Image.png").
        copy(providers.compactMap { provider in
            PastedItems.attachableType(of: provider.registeredTypeIdentifiers).map { type in
                (provider, type, PastedItems.fileName(provider.suggestedName, type: type))
            }
        })
    }

    /// Each copied out of its provider's temporary file before its callback ends, in order.
    private func copy(_ items: [(provider: NSItemProvider, type: UTType, name: String?)]) {
        guard !items.isEmpty else { return }
        let copies = copies
        copying.run { [weak self] in
            var files: [URL] = []
            for item in items {
                // the others still go; the log says why this one did not.
                if let file = await bestEffort("attached item: copy", {
                    try await PastedItems.file(from: item.provider, type: item.type, name: item.name, in: copies)
                }) {
                    files.append(file)
                }
            }
            try Task.checkCancellation()
            self?.picked(files)
        }
    }

    private func attachable(_ session: any UIDropSession) -> [NSItemProvider] {
        session.items.map(\.itemProvider).filter { PastedItems.attachableType(of: $0.registeredTypeIdentifiers) != nil }
    }

    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: any UIDropSession) -> Bool {
        !attachable(session).isEmpty
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: any UIDropSession) -> UIDropProposal {
        UIDropProposal(operation: .copy)
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: any UIDropSession) {
        take(attachable(session))
    }
}
