import AppKit
import LuxCore

/// Avatar, name and time, then two lines of the newest message and the unread count.
final class ChatCellView: NSTableCellView {
    static let reuse = NSUserInterfaceItemIdentifier("ChatCell")
    private let avatar = AvatarView(side: 40)
    private let name = NSTextField(labelWithString: "")
    private let time = NSTextField(labelWithString: "")
    private let preview = NSTextField(wrappingLabelWithString: "")
    private let badge = BadgeView()
    private var row: ChatRow?
    /// The pointer came over the row (the list starts opening the chat).
    var onHover: ((String) -> Void)?

    init() {
        super.init(frame: .zero)
        identifier = Self.reuse
        name.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail
        time.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        time.textColor = .secondaryLabelColor
        preview.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        preview.textColor = .secondaryLabelColor
        preview.maximumNumberOfLines = 2
        preview.lineBreakMode = .byWordWrapping
        preview.cell?.truncatesLastVisibleLine = true
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        preview.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        time.setContentHuggingPriority(.required, for: .horizontal)
        for view in [avatar, name, time, preview, badge] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            avatar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            avatar.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 10),
            name.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            time.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 6),
            time.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            time.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
            preview.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            preview.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 1),
            badge.leadingAnchor.constraint(greaterThanOrEqualTo: preview.trailingAnchor, constant: 6),
            badge.trailingAnchor.constraint(equalTo: time.trailingAnchor),
            badge.topAnchor.constraint(equalTo: preview.topAnchor, constant: 1),
            preview.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -32),
            // two lines, drawn from the top: every row is the same height.
            preview.heightAnchor.constraint(equalToConstant: ceil(NSFont.systemFont(ofSize: NSFont.smallSystemFontSize).boundingRectForFont.height * 2)),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if trackingAreas.isEmpty {
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        }
    }

    override func mouseEntered(with event: NSEvent) {
        if let row { onHover?(row.id) }
    }

    func show(_ row: ChatRow, images: ImagePipeline?) {
        guard row != self.row else { return }
        self.row = row
        name.stringValue = row.name
        time.stringValue = TimeText.list(row.date)
        updateTime()
        preview.stringValue = row.preview
        badge.isHidden = !row.isUnread
        badge.count = row.unreadCount
        badge.muted = row.isMuted
        avatar.show(row.avatar, name: row.name, members: row.memberAvatars, images: images)
        setAccessibilityLabel([row.name, row.isUnread ? String(localized: "unread") : nil, row.preview].compactMap { $0 }.joined(separator: ", "))
    }

    /// The shown place's accent, for an unread chat's time and badge.
    var accent = NSColor.controlAccentColor {
        didSet {
            guard accent != oldValue else { return }
            badge.color = accent
            updateTime()
        }
    }

    private func updateTime() {
        time.textColor = row.map { $0.isUnread && !$0.isMuted } == true ? accent : .secondaryLabelColor
    }

    /// The selected row's text turns white on the accent colour, as the sidebar's own rows do.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            let emphasized = backgroundStyle == .emphasized
            name.textColor = emphasized ? .alternateSelectedControlTextColor : .labelColor
            preview.textColor = emphasized ? .alternateSelectedControlTextColor.withAlphaComponent(0.8) : .secondaryLabelColor
        }
    }
}

/// A chat row whose selection keeps the accent colour while the composer has the focus, as the
/// open chat's row does in Messages (a source list greys a selection out when the table is not first
/// responder). It draws the selection itself, in the sidebar's rounded shape.
final class ChatRowView: NSTableRowView {
    static let reuse = NSUserInterfaceItemIdentifier("ChatRow")

    /// The shown place's accent.
    var accent = NSColor.controlAccentColor {
        didSet { if accent != oldValue, isSelected { needsDisplay = true } }
    }

    override var isEmphasized: Bool {
        get { true }
        set {}
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        isSelected ? .emphasized : .normal
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        accent.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 10, dy: 1), xRadius: 8, yRadius: 8).fill()
    }
}
