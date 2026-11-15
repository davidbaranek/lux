import AppKit
import LuxCore

/// A message row placed by hand from its precomputed `MessageLayout`: no Auto Layout, no measuring.
final class MessageCellView: NSTableCellView {
    static let reuse = NSUserInterfaceItemIdentifier("MessageCell")

    private let sender = TextView()
    /// A plain group's time, after its sender's name.
    private let time = TextView()
    private let bubble = FlippedView()
    /// A plain row's band behind its parts (`MessageLayout.band`).
    private let band = FlippedView()
    private let quote = TextView()
    private let photo = RemoteImageView()
    private let videoBadge = VideoBadgeView()
    private let album = AlbumView()
    private let fileRow = FileRowView()
    /// The arrow a swipe to reply uncovers at the leading edge (where the message was).
    private let replyArrow = NSImageView()
    private var replyArmed = false
    /// A shared post's card behind its media, title, caption and "Show more".
    private let postCard = FlippedView()
    private let postTitle = TextView()
    private let postText = TextView()
    private let postMore = TextView()
    private let body = TextView()
    private let footer = TextView()
    private let reactions = TextView()
    private let reactionsBackground = FlippedView()
    private let avatar = AvatarView(side: 28)
    /// A plain group's sender's picture, beside their name.
    private let plainAvatar = AvatarView(side: BubbleMetrics().plainAvatarSide)
    private let day = TextView()
    private let unreadMarker = UnreadMarkerView()
    private let readers = TextView()
    private let detail = TextView()
    /// A red mark beside a message that did not go out (as Messages shows one).
    private let failed = NSImageView(image: NSImage.symbol("exclamationmark.circle.fill", label: String(localized: "Not sent")))
    private var shown: (MessageItem, MessageLayout)?
    /// The message's menu (reactions, Copy), asked for on a right click or Control-click.
    var menuProvider: (() -> NSMenu?)?
    /// The quote of the message this one answers was clicked.
    var onQuoteTap: (() -> Void)?
    /// A link in the text was clicked.
    var onLink: ((URL) -> Void)?
    /// "Show more" (or "Show less") under a shared post's caption was clicked.
    var onPostMore: (() -> Void)?
    /// The bubble was clicked (not a link, a quote or media): its details show or hide.
    var onBubbleTap: (() -> Void)?
    /// The photo, the video, the file or an album's tile (its index) was clicked: it opens.
    var onMediaTap: ((Int) -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
    private var source: (MessageText, ImagePipeline?, Bool)?
    /// The place's colour: one's own bubbles, "New messages", the marks of one's own reactions.
    var accent = NSColor.controlAccentColor {
        didSet {
            guard accent != oldValue else { return }
            unreadMarker.accent = accent
            restyle()
        }
    }

    override var isFlipped: Bool { true }

    /// Layer colours are fixed values: resolve them again for the new appearance.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    /// Places the shown message again, its colours resolved anew.
    private func restyle() {
        guard let (message, layout) = shown, let (text, images, isGroup) = source else { return }
        shown = nil
        effectiveAppearance.performAsCurrentDrawingAppearance { show(message, layout: layout, isGroup: isGroup, text: text, images: images) }
    }

    init() {
        super.init(frame: .zero)
        identifier = Self.reuse
        wantsLayer = true
        bubble.wantsLayer = true
        bubble.layer?.cornerRadius = 16
        bubble.layer?.cornerCurve = .continuous
        photo.layer?.cornerRadius = 12
        photo.layer?.cornerCurve = .continuous
        reactionsBackground.wantsLayer = true
        reactionsBackground.layer?.backgroundColor = NSColor.incomingBubble.cgColor
        reactionsBackground.addSubview(reactions)
        photo.addSubview(videoBadge)
        postCard.wantsLayer = true
        postCard.layer?.cornerRadius = 16
        postCard.layer?.cornerCurve = .continuous
        postMore.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(postMoreClicked)))
        for view in [postCard, quote, photo, album, fileRow, postTitle, postText, postMore, body, footer] as [NSView] { bubble.addSubview(view) }
        album.onTap = { [weak self] index, _ in self?.onMediaTap?(index) }
        for view in [photo, fileRow] as [NSView] {
            view.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(mediaClicked)))
        }
        failed.contentTintColor = .systemRed
        failed.symbolConfiguration = .init(pointSize: 16, weight: .regular)
        band.wantsLayer = true
        band.layer?.cornerRadius = 6
        band.layer?.cornerCurve = .continuous
        for view in [band, day, unreadMarker, avatar, plainAvatar, sender, time, bubble, reactionsBackground, readers, detail, failed] as [NSView] {
            addSubview(view)
        }
        bubble.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(bubbleClicked)))
        band.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(bandClicked)))
        replyArrow.image = NSImage(systemSymbolName: "arrowshape.turn.up.left.circle.fill", accessibilityDescription: nil)
        replyArrow.symbolConfiguration = arrowStyle(armed: false)
        replyArrow.alphaValue = 0
        addSubview(replyArrow)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        quote.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(quoteClicked)))
        body.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(bodyClicked)))
    }

    @objc private func quoteClicked() { onQuoteTap?() }

    @objc private func postMoreClicked() { onPostMore?() }

    /// A white arrow on a filled circle: grey until letting go would reply, then the accent colour.
    private func arrowStyle(armed: Bool) -> NSImage.SymbolConfiguration {
        NSImage.SymbolConfiguration(pointSize: 26, weight: .regular)
            .applying(.init(paletteColors: [.white, armed ? accent : .systemGray]))
    }

    /// Moves the message `offset` points to the right and uncovers the arrow, which stays at the
    /// leading edge, by `progress` (0–1): the content's bounds move, the row stays.
    func setSwipe(_ offset: CGFloat, progress: CGFloat) {
        let armed = progress >= 1
        if armed != replyArmed {
            replyArmed = armed
            replyArrow.symbolConfiguration = arrowStyle(armed: armed)
        }
        setBoundsOrigin(NSPoint(x: -offset, y: 0))
        let side: CGFloat = 30
        let middle = shown?.1.bubble.midY ?? bounds.midY
        replyArrow.frame = CGRect(x: 12 - offset, y: middle - side / 2, width: side, height: side)
        replyArrow.alphaValue = progress
        let scale = 0.6 + 0.4 * progress
        replyArrow.layer?.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
    }

    /// The message slides back into place and the arrow fades.
    func settleSwipe() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            setBoundsOrigin(.zero)
            replyArrow.animator().alphaValue = 0
            replyArrow.animator().frame.origin.x = 12
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        setBoundsOrigin(.zero)
        replyArrow.alphaValue = 0
    }

    /// A click on the bubble's padding or its time; its text, quote and media handle their own.
    @objc private func bubbleClicked(_ click: NSClickGestureRecognizer) {
        let point = click.location(in: bubble)
        guard ![quote, body, photo, album, fileRow, postMore].contains(where: { !$0.isHidden && $0.frame.contains(point) }) else { return }
        onBubbleTap?()
    }

    /// A click on a plain row beside its parts.
    @objc private func bandClicked() { onBubbleTap?() }

    @objc private func mediaClicked(_ click: NSClickGestureRecognizer) {
        onMediaTap?(0)
    }

    /// Where a photo, a video, a file or an album's tile is on screen, for Quick Look's zoom.
    func mediaFrameOnScreen(at index: Int) -> NSRect? {
        if !album.isHidden { return album.frameOnScreen(of: index) }
        let view: NSView? = !photo.isHidden ? photo : !fileRow.isHidden ? fileRow : nil
        guard let view, let window else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }

    /// A click on a link opens it; elsewhere in the text it does nothing.
    @objc private func bodyClicked(_ click: NSClickGestureRecognizer) {
        guard let message = shown?.0, !message.links.isEmpty else {
            onBubbleTap?()
            return
        }
        let index = body.characterIndex(at: click.location(in: body))
        if let link = message.links.first(where: { NSLocationInRange(index, $0.range) }) { onLink?(link.url) } else { onBubbleTap?() }
    }

    /// Draws the eye to the bubble after a jump to it: the bubble takes the accent colour, then
    /// fades back to its own.
    func flash() {
        guard let (message, layout) = shown, let layer = (layout.band == nil ? bubble : band).layer else { return }
        let own = message.isOwn
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let base: NSColor, highlight: NSColor
            if layout.band != nil {
                // a plain row's band takes a wash of the accent colour.
                base = layer.backgroundColor.flatMap(NSColor.init(cgColor:)) ?? .clear
                highlight = accent.withAlphaComponent(0.25)
            } else {
                base = (own ? accent : NSColor.incomingBubble).usingColorSpace(.sRGB) ?? .gray
                // others' grey turns to the accent; one's own (already the accent) lightens.
                highlight = own ? base.blended(withFraction: 0.35, of: .white) ?? base
                                : base.blended(withFraction: 0.55, of: accent) ?? base
            }
            let pulse = CAKeyframeAnimation(keyPath: "backgroundColor")
            pulse.values = [base.cgColor, highlight.cgColor, highlight.cgColor, base.cgColor]
            pulse.keyTimes = [0, 0.12, 0.35, 1]
            pulse.duration = 1.6
            pulse.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .linear), CAMediaTimingFunction(name: .easeInEaseOut)]
            layer.add(pulse, forKey: "flash")
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(_ message: MessageItem, layout: MessageLayout, isGroup: Bool, text: MessageText, images: ImagePipeline?) {
        if let shown, shown.0 == message, shown.1 == layout { return }
        shown = (message, layout)
        source = (text, images, isGroup)
        let plain = layout.style == .plain
        // a plain row's parts are on the chat's own ground, one's own too.
        let own = message.isOwn && !plain
        let ink: NSColor = own ? .white : .labelColor
        day.isHidden = layout.day == nil
        if let frame = layout.day.map(Self.centredLine(text.footer)) {
            let centred = NSMutableParagraphStyle()
            centred.alignment = .center
            day.frame = frame
            day.set(NSAttributedString(string: message.separatorText, attributes: [
                .font: text.footer, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: centred,
            ]))
        }
        unreadMarker.isHidden = layout.unreadMarker == nil
        if let frame = layout.unreadMarker { unreadMarker.frame = frame }
        place(readers, layout.readers, message.readersText(inGroup: isGroup), text.footer, .secondaryLabelColor)
        place(detail, layout.detail, message.detailText, text.footer, .secondaryLabelColor)
        // a message that did not go out is marked as such.
        bubble.alphaValue = message.state == .failed ? 0.6 : 1
        // a plain group's name: one's own in the place's colour, others' in the text's.
        place(sender, layout.sender, message.senderName, plain ? text.author : text.sender,
              !plain ? .secondaryLabelColor : message.isOwn ? accent : .labelColor)
        place(time, layout.time, message.headerTimeText, text.footer, .secondaryLabelColor)
        bubble.frame = layout.bubble
        // the layer clips to its corners: a plain row's text, at its edge, has none.
        bubble.layer?.cornerRadius = plain ? 0 : 16
        band.isHidden = layout.band == nil
        if let frame = layout.band {
            band.frame = frame
            // a plain row has no bubble: its band shades while the details show.
            band.layer?.backgroundColor = message.showsDetail ? NSColor.labelColor.withAlphaComponent(0.07).cgColor : nil
        }
        // a clicked message darkens while its details show.
        let fill: NSColor = own ? accent : .incomingBubble
        bubble.layer?.backgroundColor = message.isMediaOnly || plain ? nil
            : (message.showsDetail ? fill.blended(withFraction: 0.22, of: .black) ?? fill : fill).cgColor
        place(quote, layout.quote, message.quoteText, text.quote, ink.withAlphaComponent(0.75))
        placeBody(message, frame: layout.body, text: text, ink: ink)
        place(footer, layout.footer, message.footerText, text.footer,
              own && !message.isMediaOnly ? NSColor.white.withAlphaComponent(0.75) : .secondaryLabelColor)
        failed.isHidden = message.state != .failed
        if message.state == .failed {
            // before a bubble; at a plain row's trailing edge, the picture column being before it.
            let x = plain ? layout.bubble.maxX + 6 : layout.bubble.minX - 24
            failed.frame = CGRect(x: x, y: layout.bubble.midY - 9, width: 18, height: 18)
        }
        reactionsBackground.isHidden = layout.reactions == nil
        if let frame = layout.reactions, let string = message.reactionsText {
            reactionsBackground.frame = frame
            reactionsBackground.layer?.cornerRadius = frame.height / 2
            let mine = message.reactions.contains(where: \.isMine)
            reactionsBackground.layer?.borderWidth = mine ? 1 : 0
            reactionsBackground.layer?.borderColor = mine ? accent.cgColor : nil
            reactions.frame = frame.offsetBy(dx: -frame.minX, dy: -frame.minY).insetBy(dx: 8, dy: 3)
            reactions.set(string, font: text.reactions, color: .labelColor)
        }
        avatar.isHidden = layout.avatar == nil || plain
        plainAvatar.isHidden = layout.avatar == nil || !plain
        if let frame = layout.avatar {
            let view = plain ? plainAvatar : avatar
            view.frame = frame
            view.show(message.senderAvatar, name: message.senderName, images: images)
        }
        album.isHidden = layout.albumTiles.isEmpty
        if let frame = layout.photo, !layout.albumTiles.isEmpty {
            album.frame = frame
            album.layer?.cornerRadius = message.isMediaOnly ? 16 : 12
            album.show(message.album, tiles: layout.albumTiles, images: images)
        }
        placePost(message, layout: layout, text: text)
        if let frame = layout.photo, let picture = message.photo, layout.albumTiles.isEmpty {
            photo.isHidden = false
            photo.frame = frame
            // a card's media fills its top, rounded with the bubble (the views are flipped, the
            // layers' minY corners are the bottom ones).
            let edge = layout.post != nil && frame.minX == 0
            photo.layer?.cornerRadius = message.isMediaOnly || edge ? 16 : 12
            photo.layer?.maskedCorners = edge ? [.layerMinXMaxYCorner, .layerMaxXMaxYCorner] : Self.allCorners
            photo.show(picture.ref, pixels: Int(frame.width * 2), images: images)
        } else {
            photo.isHidden = true
            photo.show(nil, pixels: 0, images: nil)
        }
        videoBadge.isHidden = message.video == nil || !layout.albumTiles.isEmpty
        if message.video != nil {
            videoBadge.frame = photo.bounds
            videoBadge.show(duration: message.durationText)
        }
        fileRow.isHidden = layout.file == nil
        if let frame = layout.file, let file = message.file {
            fileRow.frame = frame
            fileRow.show(file, own: own, text: text)
        }
        setAccessibilityLabel([layout.sender == nil ? nil : message.senderName, message.quote,
                               message.video != nil ? String(localized: "Video") : message.photo == nil ? nil : String(localized: "Photo"),
                               message.file.map { "\($0.name), \($0.detailText)" }, message.postCard?.title,
                               message.postCard?.description, message.body, message.footerText, message.reactionsText].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: ", "))
    }

    private static let allCorners: CACornerMask = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]

    /// A shared post's card: set apart from the message's own text by its ground, its title bold,
    /// its caption secondary and folded to its first lines, "Show more" in the accent colour.
    private func placePost(_ message: MessageItem, layout: MessageLayout, text: MessageText) {
        postCard.isHidden = layout.post == nil
        if let frame = layout.post {
            postCard.frame = frame
            // its top is the bubble's; its bottom too when nothing follows it (always in a plain row).
            postCard.layer?.maskedCorners = frame.maxY >= layout.bubble.height || layout.style == .plain ? Self.allCorners
                : [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            postCard.layer?.backgroundColor = (message.isOwn && layout.style == .bubbles ? NSColor.incomingBubble
                : NSColor.labelColor.withAlphaComponent(0.07)).cgColor
        }
        place(postTitle, layout.postTitle, message.postCard?.title, text.postTitle, .labelColor)
        place(postText, layout.postText, message.postCard?.description, text.postText, .secondaryLabelColor)
        place(postMore, layout.postMore, message.showsWholePost ? MessageItem.showLessText : MessageItem.showMoreText,
              text.postMore, accent)
    }

    /// The text, with its formatting and links (the layout measured the same string).
    private func placeBody(_ message: MessageItem, frame: CGRect?, text: MessageText, ink: NSColor) {
        body.isHidden = frame == nil
        guard let frame else { return }
        body.frame = frame
        body.set(text.bodyText(message, ink: ink, link: ink == .white ? ink : .linkColor))
    }

    /// A day's name, centred in the row's full-width rect for it.
    private static func centredLine(_ font: NSFont) -> (CGRect) -> CGRect {
        { rect in
            let height = ceil(font.ascender - font.descender + font.leading)
            return CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
        }
    }

    private func place(_ view: TextView, _ frame: CGRect?, _ string: String?, _ font: NSFont, _ color: NSColor) {
        view.isHidden = frame == nil
        guard let frame, let string else { return }
        view.frame = frame
        view.set(string, font: font, color: color)
    }
}

extension NSColor {
    /// The grey of others' bubbles: iOS's systemGray5 (#E5E5EA light, #3A3A3C dark), which AppKit
    /// does not name.
    static let incomingBubble = NSColor(name: "incomingBubble") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.227, green: 0.227, blue: 0.235, alpha: 1)
            : NSColor(srgbRed: 0.898, green: 0.898, blue: 0.918, alpha: 1)
    }
}

/// "New messages", between two hairlines in the accent colour.
private final class UnreadMarkerView: NSView {
    var accent = NSColor.controlAccentColor {
        didSet { if accent != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let text = NSAttributedString(string: String(localized: "New messages"), attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium), .foregroundColor: accent,
        ])
        let size = text.size()
        let label = NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        text.draw(in: label)
        accent.setFill()
        let y = bounds.midY, gap: CGFloat = 8, margin: CGFloat = 16
        NSRect(x: margin, y: y, width: max(0, label.minX - gap - margin), height: 1).fill()
        NSRect(x: label.maxX + gap, y: y, width: max(0, bounds.width - margin - label.maxX - gap), height: 1).fill()
    }
}
