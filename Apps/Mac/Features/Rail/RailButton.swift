import AppKit
import LuxCore

/// One place on the rail: its icon on a rounded square, a pill at the rail's edge when chosen (or
/// hovered), and its unread chats in a red badge.
final class RailButton: NSView {
    private static let side: CGFloat = 36
    private let press: (Place) -> Void
    private(set) var place: Place = .inbox
    /// The place's right-click menu (hide it).
    var menuProvider: ((Place) -> NSMenu?)?
    private var item: PlaceItem?
    /// A space's picture is in: its colour tile and initials step aside (a picture with
    /// transparent parts must not show them through).
    private var pictureShown = false
    private let tile = NSView()
    private let symbol = NSImageView()
    private let picture = RemoteImageView()
    private let initials = NSTextField(labelWithString: "")
    private let indicator = NSView()
    private let badge = BadgeView()
    private var indicatorHeight: NSLayoutConstraint!
    private var hovering = false { didSet { updateIndicator() } }

    var isSelected = false { didSet { if isSelected != oldValue { updateIndicator(); needsDisplay = true } } }

    init(press: @escaping (Place) -> Void) {
        self.press = press
        super.init(frame: .zero)
        wantsLayer = true
        tile.wantsLayer = true
        tile.layer?.cornerRadius = 10
        tile.layer?.cornerCurve = .continuous
        picture.layer?.cornerRadius = 10
        picture.layer?.cornerCurve = .continuous
        symbol.symbolConfiguration = .init(pointSize: 15, weight: .medium)
        initials.font = .systemFont(ofSize: 13, weight: .semibold)
        initials.textColor = .white
        initials.alignment = .center
        picture.onImage = { [weak self] shown in
            guard let self else { return }
            pictureShown = shown
            initials.isHidden = shown || !(item?.icon.isPicture ?? false)
            needsDisplay = true
        }
        indicator.wantsLayer = true
        // the pill grows out of the rail's edge: only its right side is round.
        indicator.layer?.cornerRadius = 2
        indicator.layer?.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        badge.color = .systemRed
        for view in [indicator, tile, badge] as [NSView] { addSubview(view) }
        for view in [initials, symbol, picture] as [NSView] { tile.addSubview(view) }
        for view in [indicator, tile, badge, symbol, picture, initials] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false }
        indicatorHeight = indicator.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: RailController.width),
            heightAnchor.constraint(equalToConstant: Self.side),
            tile.centerXAnchor.constraint(equalTo: centerXAnchor),
            tile.centerYAnchor.constraint(equalTo: centerYAnchor),
            tile.widthAnchor.constraint(equalToConstant: Self.side),
            tile.heightAnchor.constraint(equalToConstant: Self.side),
            symbol.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            symbol.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            initials.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            initials.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            picture.leadingAnchor.constraint(equalTo: tile.leadingAnchor),
            picture.trailingAnchor.constraint(equalTo: tile.trailingAnchor),
            picture.topAnchor.constraint(equalTo: tile.topAnchor),
            picture.bottomAnchor.constraint(equalTo: tile.bottomAnchor),
            indicator.leadingAnchor.constraint(equalTo: leadingAnchor),
            indicator.centerYAnchor.constraint(equalTo: centerYAnchor),
            indicator.widthAnchor.constraint(equalToConstant: 4),
            indicatorHeight,
            badge.centerXAnchor.constraint(equalTo: tile.trailingAnchor, constant: -4),
            badge.centerYAnchor.constraint(equalTo: tile.bottomAnchor, constant: -4),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?(place) ?? super.menu(for: event)
    }

    func show(_ item: PlaceItem, selected: Bool, images: ImagePipeline?) {
        self.item = item
        place = item.id
        isSelected = selected
        toolTip = item.title
        setAccessibilityLabel(item.title)
        setAccessibilityValue(item.unread > 0 ? String(localized: "\(item.unread) unread") : nil)
        badge.isHidden = item.unread == 0
        badge.count = item.unread
        symbol.isHidden = true
        picture.isHidden = true
        initials.isHidden = true
        switch item.icon {
        case .symbol(let name):
            symbol.isHidden = false
            symbol.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        case .network(let network):
            picture.isHidden = false
            picture.show(nil, pixels: 0, images: nil)
            picture.layer?.contents = NetworkImage.image(network)
            picture.layer?.contentsGravity = .resizeAspectFill
        case .picture(let ref):
            initials.stringValue = String(item.title.split(separator: " ").prefix(2).compactMap(\.first)).uppercased()
            picture.isHidden = ref == nil
            picture.show(ref, pixels: Int(Self.side * 2), images: images)
            // a picture already in (the same one, shown again for a new unread count) keeps its
            // initials hidden: they would show through its transparent parts.
            pictureShown = ref != nil && picture.hasImage
            initials.isHidden = pictureShown
        }
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let tint: NSColor = switch item?.icon {
        case .symbol?: isSelected ? .controlAccentColor : .quaternaryLabelColor
        case .picture?: pictureShown ? .clear : AvatarView.color(item?.title ?? "")
        default: .clear
        }
        tile.layer?.backgroundColor = tint.cgColor
        symbol.contentTintColor = isSelected ? .white : .secondaryLabelColor
        indicator.layer?.backgroundColor = NSColor.labelColor.cgColor
    }

    private func updateIndicator() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            indicatorHeight.animator().constant = isSelected ? 32 : hovering ? 14 : 0
        }
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { press(place) }
    override func accessibilityPerformPress() -> Bool { press(place); return true }
}

private extension PlaceItem.Icon {
    var isPicture: Bool { if case .picture = self { true } else { false } }
}
