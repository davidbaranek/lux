import AppKit
import LuxCore

/// A link, a file or a thread a search found: its symbol, a line of what it is and a line of
/// where it is, in the sidebar's rows.
final class SearchShareCell: NSTableCellView {
    static let reuse = NSUserInterfaceItemIdentifier("search-share")
    private let symbol = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.reuse
        symbol.symbolConfiguration = .init(pointSize: 15, weight: .regular)
        symbol.contentTintColor = .secondaryLabelColor
        title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.maximumNumberOfLines = 2
        detail.cell?.wraps = true
        let lines = NSStackView(views: [title, detail])
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 2
        for view in [symbol, lines] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            symbol.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            symbol.centerYAnchor.constraint(equalTo: centerYAnchor),
            symbol.widthAnchor.constraint(equalToConstant: 28),
            lines.leadingAnchor.constraint(equalTo: symbol.trailingAnchor, constant: 8),
            lines.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            lines.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(_ link: FoundLink) {
        show(symbol: "link", title: link.host, detail: "\(link.chat.name) · \(link.text)")
        toolTip = link.url
    }

    func show(_ file: FoundFile) {
        show(symbol: SearchViews.symbol(of: file), title: file.name, detail: "\(file.chat.name) · \(file.detail)")
        toolTip = file.name
    }

    func show(_ thread: FoundThread) {
        show(symbol: "bubble.left.and.text.bubble.right", title: thread.title, detail: "\(thread.chat.name) · \(thread.detail)")
        toolTip = nil
    }

    private func show(symbol name: String, title text: String, detail line: String) {
        symbol.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        title.stringValue = text
        detail.stringValue = line
    }
}

enum SearchViews {
    /// A file's symbol by its type: a document, a sound, a film, an archive.
    static func symbol(of file: FoundFile) -> String {
        let type = file.mimetype ?? ""
        if type.hasPrefix("audio/") { return "music.note" }
        if type.hasPrefix("video/") { return "film" }
        if type.contains("pdf") { return "doc.richtext" }
        if type.contains("zip") || type.contains("compressed") { return "doc.zipper" }
        return "doc"
    }

    /// A link's menu: its message in its chat, or a copy of the address.
    static func menu(for link: FoundLink, open: @escaping (SearchTarget) -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: String(localized: "Open Link")) { open(link.target) })
        menu.addItem(ClosureMenuItem(title: String(localized: "Show in Chat")) { open(link.message) })
        menu.addItem(ClosureMenuItem(title: String(localized: "Copy Link")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link.url, forType: .string)
        })
        return menu
    }
}

/// A menu item that runs its closure.
final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void

    init(title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(runClosure), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable) required init(coder: NSCoder) { fatalError() }

    @objc private func runClosure() { run() }
}

/// A section's title, and "Show All" when more of its kind were found than it shows.
final class SearchSectionHeader: NSTableCellView {
    static let reuse = NSUserInterfaceItemIdentifier("search-section")
    private let label = NSTextField(labelWithString: "")
    private lazy var showAll = NSButton(title: String(localized: "Show All"), target: self, action: #selector(showAllClicked))
    private var action: (() -> Void)?

    init() {
        super.init(frame: .zero)
        identifier = Self.reuse
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.textColor = .secondaryLabelColor
        showAll.isBordered = false
        showAll.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        showAll.contentTintColor = .controlAccentColor
        for view in [label, showAll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            // level with the rows' avatars (the source list insets its rows; a header is not inset).
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            showAll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            showAll.firstBaselineAnchor.constraint(equalTo: label.firstBaselineAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(_ title: String, showAll action: (() -> Void)?) {
        label.stringValue = title
        self.action = action
        showAll.isHidden = action == nil
    }

    @objc private func showAllClicked() { action?() }
}

/// The kinds' buttons over the results, Liquid Glass capsules: each opens its kind's list.
final class SearchKindButtons: NSView {
    var onOpen: ((SearchKind) -> Void)?
    private let row = NSStackView()
    private let scroll = NSScrollView()

    init() {
        super.init(frame: .zero)
        row.orientation = .horizontal
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 2, left: 12, bottom: 2, right: 12)
        row.setViews(SearchKind.allCases.map { kind in
            let button = NSButton(title: kind.title, image: NSImage(systemSymbolName: kind.symbol, accessibilityDescription: nil)!,
                                  target: self, action: #selector(open(_:)))
            button.bezelStyle = .glass
            button.borderShape = .capsule
            button.controlSize = .regular
            button.imagePosition = .imageLeading
            button.identifier = NSUserInterfaceItemIdentifier(kind.rawValue)
            button.setAccessibilityIdentifier("search-kind-\(kind.rawValue)")
            return button
        }, in: .leading)
        row.translatesAutoresizingMaskIntoConstraints = false
        // a narrow sidebar scrolls the row sideways.
        scroll.documentView = row
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.verticalScrollElasticity = .none
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            row.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            heightAnchor.constraint(equalTo: row.heightAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    @objc private func open(_ sender: NSButton) {
        guard let kind = sender.identifier.flatMap({ SearchKind(rawValue: $0.rawValue) }) else { return }
        onOpen?(kind)
    }
}

/// "Looking for photos by what they show…" with a spinner, in a Liquid Glass capsule, while the
/// text encoder loads: the photos found by their look follow.
final class LookingNote: NSView {
    private let glass = NSGlassEffectView()
    private let spinner = NSProgressIndicator()

    init() {
        super.init(frame: .zero)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        let label = NSTextField(wrappingLabelWithString: String(localized: "Looking for photos by what they show…"))
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        let row = NSStackView(views: [spinner, label])
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 9, left: 14, bottom: 9, right: 14)
        glass.contentView = row
        glass.cornerRadius = 18
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        NSLayoutConstraint.activate([
            glass.centerXAnchor.constraint(equalTo: centerXAnchor),
            glass.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(label.stringValue)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Shown with its spinner turning, or gone.
    var isShown: Bool = false {
        didSet {
            if isShown { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
            isHidden = !isShown
        }
    }
}
