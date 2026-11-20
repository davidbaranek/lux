import QuickLook
import UIKit
import UniformTypeIdentifiers

/// Markup on a photo or a PDF waiting in the composer, before it goes: Quick Look's editor (draw,
/// crop, rotate, add text or a signature), which saves an edited copy. The copy takes the
/// original's place in the composer (`edited`).
@MainActor
final class PendingMarkup: NSObject, @MainActor QLPreviewControllerDataSource, @MainActor QLPreviewControllerDelegate {
    private weak var host: UIViewController?
    private weak var source: UIView?
    private var file: URL?
    private let edited: (_ original: URL, _ copy: URL) -> Void

    init(host: UIViewController, edited: @escaping (_ original: URL, _ copy: URL) -> Void) {
        self.host = host
        self.edited = edited
    }

    /// A photo (not an animation, which Markup would flatten) or a PDF.
    static func canMarkUp(_ file: URL) -> Bool {
        guard let type = UTType(filenameExtension: file.pathExtension) else { return false }
        return type.conforms(to: .pdf) || (type.conforms(to: .image) && !type.conforms(to: .gif))
    }

    /// Opens `file` in Markup, growing from `view` (its tile).
    func open(_ file: URL, from view: UIView) {
        self.file = file
        source = view
        let preview = QLPreviewController()
        preview.dataSource = self
        preview.delegate = self
        host?.present(preview, animated: true)
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { file == nil ? 0 : 1 }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
        (file ?? URL(filePath: "/")) as NSURL
    }

    func previewController(_ controller: QLPreviewController, transitionViewFor item: any QLPreviewItem) -> UIView? { source }

    /// Markup is on, and what it saves is a copy: the original stays as it was.
    func previewController(_ controller: QLPreviewController, editingModeFor previewItem: any QLPreviewItem) -> QLPreviewItemEditingMode {
        .createCopy
    }

    func previewController(_ controller: QLPreviewController, didSaveEditedCopyOf previewItem: any QLPreviewItem, at modifiedContentsURL: URL) {
        guard let original = file else { return }
        // Quick Look's copy is its own to remove: it is kept under the original's name (with the
        // copy's type), in a folder of its own.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("marked up", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suffix = modifiedContentsURL.pathExtension.isEmpty ? original.pathExtension : modifiedContentsURL.pathExtension
        let copy = folder.appendingPathComponent(original.deletingPathExtension().lastPathComponent).appendingPathExtension(suffix)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: modifiedContentsURL, to: copy)
            edited(original, copy)
        } catch {
            host?.report(error, of: "markup")
        }
    }
}
