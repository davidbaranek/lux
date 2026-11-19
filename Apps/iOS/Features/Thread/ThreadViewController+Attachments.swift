import LuxCore
import Photos
import UIKit
import UniformTypeIdentifiers

/// A message's photos, videos, files and sounds kept outside the chat: copied, exported to Files,
/// added to the photo library or shared. Each is the original the session holds
/// (`ThreadModel.mediaFiles`, downloaded once); the system copies it where the user says.
extension ThreadViewController {
    /// The message's attachment actions, a section of its long-press menu.
    func attachmentMenu(for message: MessageItem) -> UIMenu? {
        let actions = AttachmentAction.available(for: message, on: .phone).map { action in
            UIAction(title: action.title(for: message), image: UIImage(systemName: action.symbol)) { [weak self] _ in
                self?.perform(action, on: message)
            }
        }
        return actions.isEmpty ? nil : UIMenu(options: .displayInline, children: actions)
    }

    private func perform(_ action: AttachmentAction, on message: MessageItem) {
        tasks.run { [weak self] in
            guard let self else { return }
            do {
                let files = try await model.mediaFiles(of: message)
                guard !files.isEmpty else { return }
                switch action {
                case .copy:
                    // each as its own type: a photo pastes as a photo, a PDF as a PDF.
                    UIPasteboard.general.itemProviders = files.compactMap { NSItemProvider(contentsOf: $0) }
                case .saveToFiles:
                    present(UIDocumentPickerViewController(forExporting: files, asCopy: true), animated: true)
                case .saveToPhotos:
                    try await PhotoLibrary.add(files)
                case .share:
                    let share = UIActivityViewController(activityItems: files, applicationActivities: nil)
                    share.popoverPresentationController?.sourceView = view
                    present(share, animated: true)
                case .saveToDownloads, .saveAs:
                    // the Mac's.
                    break
                }
            } catch is CancellationError {
            } catch {
                Log.app.error("attachment: \(String(describing: error), privacy: .public)")
                guard presentedViewController == nil else { return }
                let alert = UIAlertController(title: String(localized: "Could Not Save"), message: error.localizedDescription, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
                present(alert, animated: true)
            }
        }
    }
}

/// The photo library, which Lux may only add to (it reads nothing there).
private enum PhotoLibrary {
    struct Denied: LocalizedError {
        var errorDescription: String? {
            String(localized: "Lux may not add to your photo library. Allow it in Settings › Privacy & Security › Photos.")
        }
    }

    /// Adds the photos and videos, as they are, after asking once to add to the library.
    static func add(_ files: [URL]) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw Denied() }
        try await PHPhotoLibrary.shared().performChanges {
            for file in files {
                let isVideo = UTType(filenameExtension: file.pathExtension)?.conforms(to: .movie) ?? false
                PHAssetCreationRequest.forAsset().addResource(with: isVideo ? .video : .photo, fileURL: file, options: nil)
            }
        }
    }
}
