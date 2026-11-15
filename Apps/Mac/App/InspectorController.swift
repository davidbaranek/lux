import AppKit
import LuxCore

/// The window's inspector, the split's trailing item (closed until asked for): the open chat's
/// details, or a Matrix thread of it, whichever was asked for last. The chat stays beside it.
final class InspectorController: NSViewController {
    private(set) var shown: NSViewController?
    /// What it shows changed: the toolbar's items over it follow.
    var onShow: ((NSViewController?) -> Void)?

    override func loadView() {
        view = NSView()
    }

    /// Shows `next` in place of what it showed; nothing, with nil.
    func show(_ next: NSViewController?) {
        shown?.view.removeFromSuperview()
        shown?.removeFromParent()
        shown = next
        defer { onShow?(next) }
        guard let next else { return }
        addChild(next)
        next.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(next.view)
        NSLayoutConstraint.activate([
            next.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            next.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            next.view.topAnchor.constraint(equalTo: view.topAnchor),
            next.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
}
