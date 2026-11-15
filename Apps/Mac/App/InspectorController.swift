import AppKit
import LuxCore

/// The window's inspector, the split's trailing item (closed until asked for): the open chat's
/// details, or a Matrix thread of it, whichever was asked for last. The chat stays beside it.
final class InspectorController: NSViewController {
    private(set) var shown: NSViewController?

    override func loadView() {
        view = NSView()
    }

    /// Shows `next` in place of what it showed; nothing, with nil.
    func show(_ next: NSViewController?) {
        shown?.view.removeFromSuperview()
        shown?.removeFromParent()
        shown = next
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

/// A Matrix thread in the inspector: "Thread" and the chat's name in the toolbar's row, beside
/// the info button, with a close button; the thread's own timeline and composer under them.
final class ThreadPanelController: NSViewController {
    let thread: ThreadController
    private let chatName: String
    private let onClose: () -> Void

    init(thread: ThreadController, chatName: String, onClose: @escaping () -> Void) {
        self.thread = thread
        self.chatName = chatName
        self.onClose = onClose
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let title = NSTextField(labelWithString: String(localized: "Thread"))
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let subtitle = NSTextField(labelWithString: chatName)
        subtitle.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        let names = NSStackView(views: [title, subtitle])
        names.orientation = .vertical
        names.alignment = .leading
        names.spacing = 0
        let close = NSButton(image: NSImage.symbol("xmark", label: String(localized: "Close Thread")), target: self,
                             action: #selector(closeClicked))
        close.bezelStyle = .glass
        close.borderShape = .circle
        close.controlSize = .large
        close.toolTip = String(localized: "Close Thread")
        let header = NSStackView(views: [names, NSView(), close])
        header.orientation = .horizontal
        header.alignment = .centerY
        // the toolbar's info button sits at the row's end: the close button stays clear of it.
        header.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 60)
        let line = NSBox()
        line.boxType = .separator
        addChild(thread)
        let container = NSView()
        for view in [header, line, thread.view] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            // in the window toolbar's row, which spans the inspector too: as Messages titles it.
            header.topAnchor.constraint(equalTo: container.topAnchor),
            header.bottomAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            line.topAnchor.constraint(equalTo: header.bottomAnchor),
            line.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            thread.view.topAnchor.constraint(equalTo: line.bottomAnchor),
            thread.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            thread.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            thread.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
    }

    @objc private func closeClicked() { onClose() }
}
