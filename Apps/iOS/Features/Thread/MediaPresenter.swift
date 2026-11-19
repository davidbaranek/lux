import LuxCore
import PhotosUI
import QuickLook
import UIKit
import UniformTypeIdentifiers

/// Opens a message's photo, video or file in Quick Look, which zooms photos, plays videos, shows
/// documents and shares any of them; it grows from the bubble and shrinks back into it. The
/// original downloads first (once), with a spinner over the bubble.
@MainActor
final class MediaPresenter: NSObject, @MainActor QLPreviewControllerDataSource, @MainActor QLPreviewControllerDelegate {
    private weak var host: UIViewController?
    private weak var source: UIView?
    private var files: [URL] = []
    /// The item the preview opened at: it grows from `source` and shrinks back into it.
    private var opened = 0
    private var loading: Task<Void, Never>?

    init(host: UIViewController) {
        self.host = host
    }

    isolated deinit { loading?.cancel() }

    /// Opens a message's media (an album's every photo, at `index`), growing from `view`.
    func open(_ message: MessageItem, at index: Int = 0, from view: UIView, model: ThreadModel) {
        loading?.cancel()
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.color = .white
        spinner.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        view.addSubview(spinner)
        // only a slow download shows it: it fades in after a moment, and goes with the download.
        spinner.alpha = 0
        spinner.startAnimating()
        UIView.animate(withDuration: 0.15, delay: 0.25) { spinner.alpha = 1 }
        loading = Task { [weak self] in
            defer { spinner.removeFromSuperview() }
            do {
                let files = try await model.mediaFiles(of: message)
                guard !Task.isCancelled, let self, let host, !files.isEmpty else { return }
                self.files = files
                opened = min(index, files.count - 1)
                source = view
                let preview = QLPreviewController()
                preview.dataSource = self
                preview.delegate = self
                preview.currentPreviewItemIndex = opened
                host.present(preview, animated: true)
            } catch is CancellationError {
            } catch {
                Log.app.error("media: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { files.count }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
        files[index] as NSURL
    }

    /// The zoom from the tile and back into it, for the item it opened at.
    func previewController(_ controller: QLPreviewController, transitionViewFor item: any QLPreviewItem) -> UIView? {
        (item as? URL) == files[safe: opened] ? source : nil
    }
}

/// The composer's + : photos and videos from the library (no permission needed: the picker runs
/// out of process and hands over only what is chosen), or any file; or what is pasted or dropped.
@MainActor
final class AttachmentPicker: NSObject, @MainActor PHPickerViewControllerDelegate, @MainActor UIDocumentPickerDelegate,
    @MainActor UIDropInteractionDelegate {
    private weak var host: UIViewController?
    private let picked: ([URL]) -> Void
    /// Copying the picked photos out of the picker: it ends with the screen.
    private let copying = TaskBag()
    private var copies: URL { FileManager.default.temporaryDirectory.appendingPathComponent("picked", isDirectory: true) }

    init(host: UIViewController, picked: @escaping ([URL]) -> Void) {
        self.host = host
        self.picked = picked
    }

    var menu: UIMenu {
        UIMenu(children: [
            UIAction(title: String(localized: "Photos"), image: UIImage(systemName: "photo.on.rectangle")) { [weak self] _ in self?.pickPhotos() },
            UIAction(title: String(localized: "Files"), image: UIImage(systemName: "folder")) { [weak self] _ in self?.pickFiles() },
        ])
    }

    private func pickPhotos() {
        var configuration = PHPickerConfiguration()
        configuration.selectionLimit = 10
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

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        picked(urls)
    }

    // MARK: Dropped on the chat

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

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
