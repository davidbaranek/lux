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
/// out of process and hands over only what is chosen), or any file.
@MainActor
final class AttachmentPicker: NSObject, @MainActor PHPickerViewControllerDelegate, @MainActor UIDocumentPickerDelegate {
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
        guard !results.isEmpty else { return }
        let copies = copies
        copying.run { [weak self] in
            // each copied out of the picker's temporary file before its callback ends, in order.
            var files: [URL] = []
            for result in results {
                let provider = result.itemProvider
                guard let type = [UTType.movie, .image].first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) else { continue }
                // the others still go; the log says why this one did not.
                if let file = await bestEffort("picked media: copy", { try await Self.copy(from: provider, type: type, into: copies) }) {
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

    private static func copy(from provider: NSItemProvider, type: UTType, into folder: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, error in
                guard let url else { return continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
                do {
                    let target = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                    let copy = target.appendingPathComponent(url.lastPathComponent)
                    try FileManager.default.copyItem(at: url, to: copy)
                    continuation.resume(returning: copy)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
