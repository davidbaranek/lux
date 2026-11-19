import AppKit
import LuxCore
import QuickLookUI

/// A message's photos, videos and files in Quick Look.
extension ThreadController {
    /// Opens a message's photo, video or file in Quick Look (an album's every photo, at `index`),
    /// zooming from it; the arrow keys go through an album, then on to the chat's other media.
    /// Downloaded first, once. Its row is the table's selection: Space opens it again.
    func openMedia(_ message: MessageItem, at index: Int, from frame: NSRect?) {
        if let row = order.firstIndex(of: message.id) { table.selectRowIndexes([row], byExtendingSelection: false) }
        // a newer one replaces it; the download ends with the chat.
        tasks.run("media") { [weak self, model] in
            let files = try await model.mediaFiles(of: message)
            guard let self, !files.isEmpty else { return }
            let opened = min(index, files.count - 1)
            preview = (files, opened, frame)
            guard let panel = QLPreviewPanel.shared() else { return }
            view.window?.makeFirstResponder(table)
            if panel.isVisible { panel.reloadData() } else { panel.makeKeyAndOrderFront(nil) }
            panel.currentPreviewItemIndex = opened
        }
    }

    /// Space: the selected message's media in Quick Look, or Quick Look closed again.
    override func quickLookPreviewItems(_ sender: Any?) {
        if preview != nil, QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible {
            return panel.orderOut(nil)
        }
        let row = table.selectedRow
        guard order.indices.contains(row), let message = messages[order[row]], message.hasMedia else { return NSSound.beep() }
        openMedia(message, at: 0, from: mediaFrame(atRow: row, index: 0))
    }

    /// The chat's previous or next message with media from the selected one, selected and shown in
    /// Quick Look; false at either end.
    func stepMedia(by step: Int) -> Bool {
        var row = table.selectedRow
        repeat { row += step } while order.indices.contains(row) && messages[order[row]]?.hasMedia != true
        guard order.indices.contains(row), let message = messages[order[row]] else { return false }
        table.scrollRowToVisible(row)
        // back into an album: at its last photo.
        let index = step < 0 ? message.mediaMessageIds.count - 1 : 0
        openMedia(message, at: index, from: mediaFrame(atRow: row, index: index))
        return true
    }

    private func mediaFrame(atRow row: Int, index: Int) -> NSRect? {
        (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? MessageCellView)?.mediaFrameOnScreen(at: index)
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

    /// The arrow keys Quick Look leaves (past an album's ends, or a single item) go through the
    /// chat's media, as in Finder.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        switch event.specialKey {
        case .upArrow?, .leftArrow?: return stepMedia(by: -1)
        case .downArrow?, .rightArrow?: return stepMedia(by: 1)
        default: return false
        }
    }

    /// The zoom from the photo it opened at and back into it.
    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: (any QLPreviewItem)!) -> NSRect {
        guard let preview, (item as? URL) == preview.files[preview.opened] else { return .zero }
        return preview.frame ?? .zero
    }
}
