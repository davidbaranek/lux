import AppKit
import LuxCore
import QuickLookUI

/// A message's photos, videos and files in Quick Look.
extension ThreadController {
    /// Opens a message's photo, video or file in Quick Look (an album's every photo, at `index`),
    /// zooming from it; the arrow keys go through an album. Downloaded first, once.
    func openMedia(_ message: MessageItem, at index: Int, from frame: NSRect?) {
        Task {
            do {
                let files = try await model.mediaFiles(of: message)
                guard !files.isEmpty else { return }
                let opened = min(index, files.count - 1)
                preview = (files, opened, frame)
                guard let panel = QLPreviewPanel.shared() else { return }
                view.window?.makeFirstResponder(table)
                if panel.isVisible { panel.reloadData() } else { panel.makeKeyAndOrderFront(nil) }
                panel.currentPreviewItemIndex = opened
            } catch {
                Log.app.error("media: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // Quick Look asks the responder chain on the main thread; these overrides are not marked so.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { preview != nil }
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = self
            panel.delegate = self
        }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
            preview = nil
        }
    }
}

extension ThreadController: @MainActor QLPreviewPanelDataSource, @MainActor QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { preview?.files.count ?? 0 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        preview.map { $0.files[index] as NSURL }
    }

    /// The zoom from the photo it opened at and back into it.
    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: (any QLPreviewItem)!) -> NSRect {
        guard let preview, (item as? URL) == preview.files[preview.opened] else { return .zero }
        return preview.frame ?? .zero
    }
}
