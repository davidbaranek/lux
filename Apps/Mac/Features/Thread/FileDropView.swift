import AppKit

/// The chat's view, which takes files dropped on it from Finder or another app: each goes as a
/// message. It lightens while they hover over it.
final class FileDropView: NSView {
    var onDrop: (([URL]) -> Void)?
    /// A live resize ended: the window's edge let go, or the split beside it done animating.
    var onEndLiveResize: (() -> Void)?
    private let highlight = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        highlight.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
        highlight.borderColor = NSColor.controlAccentColor.cgColor
        highlight.borderWidth = 2
        highlight.cornerRadius = 12
        highlight.isHidden = true
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        onEndLiveResize?()
    }

    override func layout() {
        super.layout()
        if highlight.superlayer == nil { layer?.addSublayer(highlight) }
        highlight.frame = bounds.insetBy(dx: 8, dy: 8)
    }

    private func files(_ info: any NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    override func draggingEntered(_ info: any NSDraggingInfo) -> NSDragOperation {
        guard !files(info).isEmpty else { return [] }
        highlight.isHidden = false
        return .copy
    }

    override func draggingExited(_ info: (any NSDraggingInfo)?) { highlight.isHidden = true }

    override func performDragOperation(_ info: any NSDraggingInfo) -> Bool {
        highlight.isHidden = true
        let dropped = files(info)
        guard !dropped.isEmpty else { return false }
        onDrop?(dropped)
        return true
    }
}
