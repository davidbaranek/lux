import LuxCore
import QuickLook
import UIKit

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

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
