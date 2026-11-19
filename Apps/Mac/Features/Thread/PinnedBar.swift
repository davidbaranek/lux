import AppKit
import LuxCore

/// The chat's pinned messages, in a glass bar over its top: one at a time, the newest pinned
/// first. A click goes to it and shows the one pinned before it (round again after the oldest);
/// its menu (a right-click, or the list button) lists them all, to go to any. Hidden while none
/// is pinned.
final class PinnedBar: NSView {
    /// Go to a pinned message.
    var onJump: ((PinnedMessage) -> Void)?
    private var pinned: [PinnedMessage] = []
    /// The one shown, counted from the newest.
    private var shown = 0
    private let button = NSButton()
    private let list = NSButton()

    init() {
        super.init(frame: .zero)
        button.bezelStyle = .glass
        button.controlSize = .large
        button.image = NSImage.symbol("pin.fill", label: String(localized: "Pinned"))
        button.imagePosition = .imageLeading
        button.alignment = .left
        button.lineBreakMode = .byTruncatingTail
        button.target = self
        button.action = #selector(jump)
        list.bezelStyle = .glass
        list.controlSize = .large
        list.image = NSImage.symbol("list.bullet", label: String(localized: "All Pinned Messages"))
        list.toolTip = String(localized: "All Pinned Messages")
        list.target = self
        list.action = #selector(showList)
        let row = NSStackView(views: [button, list])
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        isHidden = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Shows `pinned` (in the order they were pinned): a message just pinned first, else the one
    /// shown while it stays pinned.
    func show(_ pinned: [PinnedMessage]) {
        let current = self.pinned.reversed().dropFirst(shown).first
        let newlyPinned = pinned.last.map { !self.pinned.contains($0) } ?? false
        self.pinned = pinned
        shown = newlyPinned ? 0 : current.flatMap { current in Array(pinned.reversed()).firstIndex(of: current) } ?? 0
        isHidden = pinned.isEmpty
        list.isHidden = pinned.count < 2
        menu = listMenu()
        update()
    }

    private func update() {
        let newestFirst = Array(pinned.reversed())
        guard newestFirst.indices.contains(shown) else { return }
        let pin = newestFirst[shown]
        let heading = newestFirst.count > 1
            ? String(localized: "Pinned Message \(shown + 1) of \(newestFirst.count)")
            : String(localized: "Pinned Message")
        let line = pin.text.isEmpty ? pin.senderName : "\(pin.senderName): \(pin.text)"
        let title = NSMutableAttributedString(string: heading + "  ", attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
            .foregroundColor: NSColor.controlAccentColor,
        ])
        title.append(NSAttributedString(string: line, attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]))
        button.attributedTitle = title
        button.setAccessibilityLabel(String(localized: "Pinned message from \(pin.senderName): \(pin.text)"))
    }

    private func listMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Pinned Messages"))
        for pin in pinned.reversed() {
            let item = NSMenuItem(title: pin.text.isEmpty ? pin.senderName : pin.text, action: #selector(choose(_:)), keyEquivalent: "")
            item.subtitle = pin.senderName
            item.image = NSImage.symbol("pin", label: String(localized: "Pinned"))
            item.target = self
            item.representedObject = pin.eventId
            menu.addItem(item)
        }
        return menu
    }

    @objc private func jump() {
        let newestFirst = Array(pinned.reversed())
        guard newestFirst.indices.contains(shown) else { return }
        onJump?(newestFirst[shown])
        shown = (shown + 1) % newestFirst.count
        update()
    }

    @objc private func showList() {
        listMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: list.frame.minY - 4), in: list)
    }

    @objc private func choose(_ item: NSMenuItem) {
        guard let event = item.representedObject as? String, let pin = pinned.first(where: { $0.eventId == event }) else { return }
        onJump?(pin)
    }
}
