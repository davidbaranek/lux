import AppKit
import LuxCore

/// An open chat, and beside it the Matrix thread opened from it, as a split the user resizes: the
/// chat stays on the left, the thread is in a panel on the right (its root, its replies, its own
/// composer) until its close button closes it. Another thread opened takes the panel's place.
final class ChatSplitController: NSSplitViewController {
    private let session: Session
    private let row: ChatRow
    /// The chat itself.
    let chat: ThreadController
    /// The thread beside it, while one is open.
    private(set) var thread: ThreadController?
    private var panel: NSSplitViewItem?
    var theme: PlaceTheme {
        didSet {
            chat.theme = theme
            thread?.theme = theme
        }
    }

    /// The panel's narrowest and its share of the pane when it opens.
    private static let panelMinimum: CGFloat = 320
    private static let panelShare: CGFloat = 0.45

    init(session: Session, row: ChatRow, chat: ThreadController) {
        self.session = session
        self.row = row
        self.chat = chat
        theme = chat.theme
        super.init(nibName: nil, bundle: nil)
        chat.onOpenThread = { [weak self] thread in self?.open(thread) }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        let item = NSSplitViewItem(viewController: chat)
        item.minimumThickness = 360
        // the window resizing: the chat grows and shrinks, the thread keeps its width.
        item.holdingPriority = .defaultLow
        addSplitViewItem(item)
    }

    /// Shows `matrixThread` in the panel beside the chat (it opens, or takes the open one's place).
    func open(_ matrixThread: MatrixThread) {
        if let thread, thread.model.thread == matrixThread {
            view.window?.makeFirstResponder(thread.field)
            return
        }
        let controller = ThreadController(session: session, row: row, theme: theme, thread: matrixThread)
        let content = ThreadPanelController(thread: controller, chatName: row.name) { [weak self] in self?.closeThread() }
        let item = NSSplitViewItem(viewController: content)
        item.minimumThickness = Self.panelMinimum
        item.holdingPriority = .defaultLow + 1
        if let panel { removeSplitViewItem(panel) }
        let opening = panel == nil
        addSplitViewItem(item)
        panel = item
        thread = controller
        if opening {
            splitView.layoutSubtreeIfNeeded()
            let width = splitView.bounds.width
            splitView.setPosition(max(width * (1 - Self.panelShare), width - max(Self.panelMinimum, width * Self.panelShare)),
                                  ofDividerAt: 0)
        }
    }

    /// Closes the thread's panel: the chat takes the pane again.
    func closeThread() {
        guard let panel else { return }
        removeSplitViewItem(panel)
        self.panel = nil
        thread = nil
        view.window?.makeFirstResponder(chat.field)
    }
}

/// The thread's panel: "Thread" and the chat's name over it, a close button at its end; the
/// thread's own timeline and composer under them.
private final class ThreadPanelController: NSViewController {
    private let thread: ThreadController
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
        close.toolTip = String(localized: "Close Thread")
        let header = NSStackView(views: [names, NSView(), close])
        header.orientation = .horizontal
        header.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 12)
        let line = NSBox()
        line.boxType = .separator
        addChild(thread)
        let container = NSView()
        for view in [header, line, thread.view] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            // under the window's toolbar, which spans the chat and the panel.
            header.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
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
