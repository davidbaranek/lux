import LuxCore
import UIKit

/// A message row laid out by hand from its precomputed `MessageLayout`: no Auto Layout pass and no
/// self-sizing, so showing a row costs a few frame assignments.
final class MessageCell: UICollectionViewCell {
    let bubble = UIView()
    /// A plain row's band behind its parts (`MessageLayout.band`).
    let band = UIView()
    private let day = UILabel()
    private let unreadMarker = UnreadMarkerView()
    private let sender = UILabel()
    /// A plain group's time, after its sender's name.
    private let time = UILabel()
    /// Over a plain reply: the answered sender's picture and their message on one line, linked
    /// to the sender's picture below.
    private let replyLine = UILabel()
    private let replyAvatar = AvatarView()
    private let replyLink = ReplyLinkView()
    private let quote = UILabel()
    private let photo = RemoteImageView()
    private let videoBadge = VideoBadgeView()
    private let album = AlbumView()
    private lazy var fileRow = FileRowView(metrics: BubbleMetrics())
    /// A shared post's card behind its media, title, caption and "Show more".
    private let postCard = UIView()
    private let postTitle = UILabel()
    private let postText = UILabel()
    private let postMore = UILabel()
    private let body = UILabel()
    private let footer = UILabel()
    private let reactions = UILabel()
    private let readers = UILabel()
    private let detail = UILabel()
    private let avatar = AvatarView()
    /// A red mark beside a message that did not go out (as Messages shows one).
    private let failed = UIImageView(image: UIImage(systemName: "exclamationmark.circle.fill"))
    /// The arrow a swipe to reply uncovers at the leading edge (outside the content, which moves).
    private let replyArrow = UIImageView(image: UIImage(systemName: "arrowshape.turn.up.left.circle.fill"))
    /// One's own bubbles: the place's colour, else the system's blue. A fixed colour, not
    /// .tintColor: the tint dims while a menu is open, and the lifted bubble with it.
    var ownFill = UIColor.systemBlue {
        didSet {
            guard ownFill != oldValue, let (message, layout) = shown else { return }
            fillBubble(message)
            if layout.style == .plain, message.isOwn { sender.textColor = ownFill }
        }
    }
    private var shown: (MessageItem, MessageLayout)?
    /// The quote of the message this one answers was tapped.
    var onQuoteTap: (() -> Void)?
    /// A link in the text was tapped.
    var onLink: ((URL) -> Void)?
    /// The bubble was tapped (not a link, a quote or media): its details show or hide.
    var onBubbleTap: (() -> Void)?
    /// "Show more" (or "Show less") under a shared post's caption was tapped.
    var onPostMore: (() -> Void)?
    /// A tap on a shared post's title or caption: opens the post.
    var onPostOpen: (() -> Void)?
    /// The photo, the video, the file or an album's tile (its index) was tapped: it opens,
    /// growing from this view.
    var onMediaTap: ((UIView, Int) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        day.textAlignment = .center
        day.textColor = .secondaryLabel
        time.textColor = .secondaryLabel
        quote.numberOfLines = 2
        body.numberOfLines = 0
        readers.textColor = .secondaryLabel
        detail.textColor = .secondaryLabel
        reactions.textAlignment = .center
        reactions.backgroundColor = .systemGray5
        reactions.layer.cornerCurve = .continuous
        reactions.layer.masksToBounds = true
        // round corners on the layers themselves, no masks (no offscreen pass for the bubble).
        bubble.layer.cornerRadius = 18
        bubble.layer.cornerCurve = .continuous
        photo.contentMode = .scaleAspectFill
        photo.layer.cornerRadius = 14
        photo.layer.cornerCurve = .continuous
        photo.layer.masksToBounds = true
        photo.backgroundColor = .tertiarySystemFill
        photo.addSubview(videoBadge)
        postCard.layer.cornerRadius = 18
        postCard.layer.cornerCurve = .continuous
        postTitle.numberOfLines = 2
        // an unfolding caption shows its top while it grows, the rest coming into view.
        postText.contentMode = .top
        postText.clipsToBounds = true
        postTitle.isUserInteractionEnabled = true
        postTitle.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(postTitleTapped)))
        postText.isUserInteractionEnabled = true
        postText.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(postTitleTapped)))
        postMore.isUserInteractionEnabled = true
        postMore.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(postMoreTapped)))
        for view in [postCard, quote, photo, album, fileRow, postTitle, postText, postMore, body, footer] { bubble.addSubview(view) }
        album.onTap = { [weak self] index, tile in self?.onMediaTap?(tile, index) }
        for view in [photo, fileRow] as [UIView] {
            view.isUserInteractionEnabled = true
            view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(mediaTapped)))
        }
        avatar.side = 28
        failed.tintColor = .systemRed
        band.layer.cornerRadius = 10
        band.layer.cornerCurve = .continuous
        replyLine.lineBreakMode = .byTruncatingTail
        replyLine.isUserInteractionEnabled = true
        replyLine.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(quoteTapped)))
        replyAvatar.side = BubbleMetrics().replyAvatarSide
        for view in [band, day, unreadMarker, avatar, sender, time, replyLink, replyAvatar, replyLine, bubble, reactions, readers, detail, failed] {
            contentView.addSubview(view)
        }
        bubble.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(bubbleTapped)))
        band.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(bandTapped)))
        replyArrow.preferredSymbolConfiguration = Self.arrowStyle(armed: false)
        replyArrow.layer.shadowOpacity = 0.15
        replyArrow.layer.shadowRadius = 4
        replyArrow.layer.shadowOffset = .zero
        replyArrow.alpha = 0
        addSubview(replyArrow)
        isAccessibilityElement = true
        quote.isUserInteractionEnabled = true
        quote.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(quoteTapped)))
        body.isUserInteractionEnabled = true
        body.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(bodyTapped)))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    @objc private func quoteTapped() { onQuoteTap?() }

    @objc private func postMoreTapped() { onPostMore?() }

    @objc private func postTitleTapped() { onPostOpen?() }

    /// A tap on the bubble's padding or its time; its text, quote and media handle their own.
    @objc private func bubbleTapped(_ tap: UITapGestureRecognizer) {
        let point = tap.location(in: bubble)
        guard ![quote, body, photo, album, fileRow, postTitle, postText, postMore].contains(where: { !$0.isHidden && $0.frame.contains(point) }) else { return }
        onBubbleTap?()
    }

    /// A tap on a plain row beside its parts.
    @objc private func bandTapped() { onBubbleTap?() }

    @objc private func mediaTapped(_ tap: UITapGestureRecognizer) {
        if let view = tap.view { onMediaTap?(view, 0) }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        setSwipe(0, progress: 0)
    }

    /// Moves the message `offset` points to the right and uncovers the reply arrow, which stays at
    /// the leading edge, by `progress` (0–1).
    private var replyArmed = false

    /// A white arrow on a filled circle: grey until letting go would reply, then the accent colour.
    private static func arrowStyle(armed: Bool) -> UIImage.SymbolConfiguration {
        UIImage.SymbolConfiguration(pointSize: 30)
            .applying(UIImage.SymbolConfiguration(paletteColors: [.white, armed ? .tintColor : .systemGray2]))
    }

    func setSwipe(_ offset: CGFloat, progress: CGFloat) {
        // the colour changes only at the threshold: a new symbol configuration lays the cell out
        // again.
        let armed = progress >= 1
        if armed != replyArmed {
            replyArmed = armed
            replyArrow.preferredSymbolConfiguration = Self.arrowStyle(armed: armed)
        }
        let size = replyArrow.intrinsicContentSize
        let bubble = shown?.1.bubble ?? bounds
        replyArrow.bounds = CGRect(origin: .zero, size: size)
        // the content's bounds move rather than a transform: the cell's layout pass sets the content
        // view's frame, which keeps the bounds' origin but would undo a transform.
        contentView.bounds.origin.x = -offset
        replyArrow.center = CGPoint(x: 12 + size.width / 2, y: bubble.midY)
        replyArrow.alpha = progress
        let scale = 0.6 + 0.4 * progress
        replyArrow.transform = CGAffineTransform(scaleX: scale, y: scale)
    }

    /// A tap on a link opens it; elsewhere in the text it does nothing.
    @objc private func bodyTapped(_ tap: UITapGestureRecognizer) {
        guard let message = shown?.0, !message.links.isEmpty, let text = body.attributedText else {
            onBubbleTap?()
            return
        }
        let index = LinkHit.characterIndex(at: tap.location(in: body), in: text, size: body.bounds.size)
        if let link = message.links.first(where: { NSLocationInRange(index, $0.range) }) { onLink?(link.url) } else { onBubbleTap?() }
    }

    /// Draws the eye to the bubble after a jump to it: the bubble takes the accent colour, then
    /// fades back to its own.
    func flash() {
        guard let (message, layout) = shown else { return }
        if layout.band != nil { return flashBand() }
        guard let base = bubble.backgroundColor?.resolvedColor(with: traitCollection) else { return }
        let own = message.isOwn
        // others' grey turns to the accent; one's own (already the accent) lightens.
        let highlight = own ? base.blended(with: .white, by: 0.35)
                            : base.blended(with: tintColor.resolvedColor(with: traitCollection), by: 0.55)
        let pulse = CAKeyframeAnimation(keyPath: "backgroundColor")
        pulse.values = [base.cgColor, highlight.cgColor, highlight.cgColor, base.cgColor]
        pulse.keyTimes = [0, 0.12, 0.35, 1]
        pulse.duration = 1.6
        pulse.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .linear), CAMediaTimingFunction(name: .easeInEaseOut)]
        bubble.layer.add(pulse, forKey: "flash")
    }

    /// A plain row's band takes a wash of the accent colour, then fades back to its own.
    private func flashBand() {
        let base = (band.backgroundColor ?? .clear).resolvedColor(with: traitCollection)
        let highlight = ownFill.resolvedColor(with: traitCollection).withAlphaComponent(0.25)
        let pulse = CAKeyframeAnimation(keyPath: "backgroundColor")
        pulse.values = [base.cgColor, highlight.cgColor, highlight.cgColor, base.cgColor]
        pulse.keyTimes = [0, 0.12, 0.35, 1]
        pulse.duration = 1.6
        pulse.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .linear), CAMediaTimingFunction(name: .easeInEaseOut)]
        band.layer.add(pulse, forKey: "flash")
    }

    /// What lifts for the menu: a bubble in its own shape, a plain row's band across the row.
    var menuPreview: UITargetedPreview {
        let parameters = UIPreviewParameters()
        guard let frame = shown?.1.band else {
            parameters.visiblePath = UIBezierPath(roundedRect: bubble.bounds, cornerRadius: bubble.layer.cornerRadius)
            parameters.backgroundColor = .clear
            return UITargetedPreview(view: bubble, parameters: parameters)
        }
        parameters.visiblePath = UIBezierPath(roundedRect: frame, cornerRadius: band.layer.cornerRadius)
        parameters.backgroundColor = .systemBackground
        return UITargetedPreview(view: contentView, parameters: parameters)
    }

    func show(_ message: MessageItem, layout: MessageLayout, isGroup: Bool, text: MessageText, images: ImagePipeline?) {
        if let shown, shown.0 == message, shown.1 == layout { return }
        shown = (message, layout)
        let plain = layout.style == .plain
        // a plain row's parts are on the chat's own ground, one's own too.
        let own = message.isOwn && !plain
        let ink: UIColor = own ? .white : .label

        place(day, layout.day, message.separatorText, text.footer)
        unreadMarker.isHidden = layout.unreadMarker == nil
        if let frame = layout.unreadMarker { unreadMarker.frame = frame }
        place(sender, layout.sender, message.senderName, plain ? text.author : text.sender)
        // one's own name in the place's colour, others' in the text's.
        sender.textColor = !plain ? .secondaryLabel : message.isOwn ? ownFill : .label
        place(time, layout.time, message.headerTimeText, text.footer)
        placeReply(message, layout: layout, text: text, images: images)
        band.isHidden = layout.band == nil
        if let frame = layout.band { band.frame = frame }
        bubble.frame = layout.bubble
        fillBubble(message)
        // a message that did not go out is marked as such.
        bubble.alpha = message.state == .failed ? 0.6 : 1
        place(quote, layout.quote, message.quoteText, text.quote)
        quote.textColor = ink.withAlphaComponent(0.75)
        placeBody(message, frame: layout.body, text: text, ink: ink)
        place(footer, layout.footer, message.footerText, text.footer)
        footer.textColor = own && !message.isMediaOnly ? UIColor.white.withAlphaComponent(0.75) : .secondaryLabel
        failed.isHidden = message.state != .failed
        if message.state == .failed {
            // before a bubble; at a plain row's trailing edge, the picture column being before it.
            let x = plain ? layout.bubble.maxX + 6 : layout.bubble.minX - 26
            failed.frame = CGRect(x: x, y: layout.bubble.midY - 10, width: 20, height: 20)
        }
        place(reactions, layout.reactions, message.reactionsText, text.reactions)
        reactions.layer.cornerRadius = (layout.reactions?.height ?? 0) / 2
        let mine = message.reactions.contains(where: \.isMine)
        reactions.layer.borderWidth = mine ? 1 : 0
        reactions.layer.borderColor = mine ? UIColor.tintColor.cgColor : nil
        place(readers, layout.readers, message.readersText(inGroup: isGroup), text.footer)
        place(detail, layout.detail, message.detailText, text.footer)

        avatar.isHidden = layout.avatar == nil
        if let frame = layout.avatar {
            avatar.side = frame.width
            avatar.frame = frame
            avatar.show(message.senderAvatar, name: message.senderName, images: images)
        }

        album.isHidden = layout.albumTiles.isEmpty
        if let frame = layout.photo, !layout.albumTiles.isEmpty {
            album.frame = frame
            album.layer.cornerRadius = message.isMediaOnly ? 18 : 14
            album.show(message.album, tiles: layout.albumTiles, images: images, scale: traitCollection.displayScale)
        }
        placePost(message, layout: layout, text: text)
        if let frame = layout.photo, let picture = message.photo, layout.albumTiles.isEmpty {
            photo.isHidden = false
            photo.frame = frame
            // a card's media fills its top, rounded with the bubble.
            let edge = layout.post != nil && frame.minX == 0
            photo.layer.cornerRadius = message.isMediaOnly || edge ? 18 : 14
            photo.layer.maskedCorners = edge ? [.layerMinXMinYCorner, .layerMaxXMinYCorner] : Self.allCorners
            photo.show(picture.ref, pixels: Int(frame.width * traitCollection.displayScale), images: images)
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
        accessibilityLabel = [layout.sender == nil ? nil : message.senderName, message.quoteText,
                              message.album.count > 1 ? String(localized: "\(message.album.count) photos")
                                : message.video != nil ? String(localized: "Video") : message.photo == nil ? nil : String(localized: "Photo"),
                              message.file.map { "\($0.name), \($0.detailText)" }, message.postCard?.title, message.postCard?.description,
                              message.body, message.footerText, message.reactionsText, message.readersText(inGroup: isGroup)]
            .compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: ", ")
    }

    /// A plain reply's line, as Discord draws one: the quoted sender's picture and name, then
    /// their message in the secondary colour, a rounded line from the sender's picture up to it.
    private func placeReply(_ message: MessageItem, layout: MessageLayout, text: MessageText, images: ImagePipeline?) {
        let quote = layout.reply == nil ? nil : message.quote
        replyLine.isHidden = quote == nil
        replyAvatar.isHidden = quote == nil
        replyLink.isHidden = quote == nil
        guard let quote, let line = layout.reply, let picture = layout.replyAvatar, let link = layout.replyLink else { return }
        replyLine.frame = line
        let words = NSMutableAttributedString()
        if !quote.senderName.isEmpty {
            words.append(NSAttributedString(string: quote.senderName + " ", attributes: [.font: text.quote.bold, .foregroundColor: UIColor.label]))
        }
        words.append(NSAttributedString(string: quote.text, attributes: [.font: text.quote, .foregroundColor: UIColor.secondaryLabel]))
        replyLine.attributedText = words
        replyAvatar.frame = picture
        replyAvatar.show(quote.senderAvatar, name: quote.senderName, images: images)
        replyLink.frame = link
    }

    private static let allCorners: CACornerMask = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]

    /// A shared post's card: set apart from the message's own text by its ground, its title bold,
    /// its caption secondary and folded to its first lines, "Show more" in the accent colour.
    private func placePost(_ message: MessageItem, layout: MessageLayout, text: MessageText) {
        postCard.isHidden = layout.post == nil
        if let frame = layout.post {
            postCard.frame = frame
            // its top is the bubble's; its bottom too when nothing follows it (always in a plain row).
            postCard.layer.maskedCorners = frame.maxY >= layout.bubble.height || layout.style == .plain ? Self.allCorners
                : [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            postCard.backgroundColor = message.isOwn && layout.style == .bubbles ? .systemGray5 : Self.cardOnGrey
        }
        place(postTitle, layout.postTitle, message.postCard?.title, text.postTitle)
        postTitle.textColor = .label
        place(postText, layout.postText, message.postCard?.description, text.postText)
        postText.textColor = .secondaryLabel
        postText.numberOfLines = layout.postFolded ? BubbleMetrics().postLines : 0
        place(postMore, layout.postMore, message.showsWholePost ? MessageItem.showLessText : MessageItem.showMoreText, text.postMore)
        postMore.textColor = .tintColor
    }

    /// A card on others' grey bubble: a shade darker (lighter in the dark).
    private static let cardOnGrey = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor.white.withAlphaComponent(0.08) : UIColor.black.withAlphaComponent(0.06)
    }

    /// The text, with its formatting and links (the layout measured the same string).
    private func placeBody(_ message: MessageItem, frame: CGRect?, text: MessageText, ink: UIColor) {
        body.isHidden = frame == nil
        guard let frame else { return }
        body.frame = frame
        if message.links.isEmpty, message.styles.isEmpty {
            body.attributedText = nil
            body.font = text.body
            body.textColor = ink
            body.text = message.body
            return
        }
        body.attributedText = text.bodyText(message, ink: ink, link: ink == .white ? ink : .link)
    }

    /// The bubble's colour; a tapped message darkens while its details show. A plain row has no
    /// bubble: its band shades while the details show.
    private func fillBubble(_ message: MessageItem) {
        if shown?.1.style == .plain {
            bubble.backgroundColor = .clear
            band.backgroundColor = message.showsDetail ? .tertiarySystemFill : .clear
            return
        }
        let own = ownFill
        bubble.backgroundColor = message.isMediaOnly ? .clear
            : message.isOwn ? (message.showsDetail ? UIColor { own.resolvedColor(with: $0).darkened(by: 0.22) } : own)
            : (message.showsDetail ? .systemGray4 : .systemGray5)
    }

    private func place(_ label: UILabel, _ frame: CGRect?, _ text: String?, _ font: UIFont) {
        let appearing = label.isHidden && frame != nil
        label.isHidden = frame == nil
        guard let frame else { return }
        label.font = font
        label.text = text
        // a label coming into view takes its place at once and fades in: inside the list's
        // animated update it would otherwise fly in from where it last was.
        guard appearing else { return label.frame = frame }
        UIView.performWithoutAnimation { label.frame = frame }
        label.alpha = 0
        UIView.animate(withDuration: 0.2) { label.alpha = 1 }
    }
}

/// The line from a plain reply's sender up and round to the message it answers.
private final class ReplyLinkView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        contentMode = .redraw
        isUserInteractionEnabled = false
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let width: CGFloat = 2
        context.addPath(MessageLayout.replyLinkPath(size: bounds.size, lineWidth: width))
        context.setLineWidth(width)
        context.setLineCap(.round)
        context.setStrokeColor(UIColor.tertiaryLabel.cgColor)
        context.strokePath()
    }
}

/// "New messages", between two hairlines in the accent colour.
private final class UnreadMarkerView: UIView {
    private let label = UILabel()
    private let left = UIView(), right = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.text = String(localized: "New messages")
        label.font = .preferredFont(forTextStyle: .caption1)
        label.textColor = .tintColor
        label.textAlignment = .center
        for line in [left, right] { line.backgroundColor = .tintColor }
        for view in [left, label, right] { addSubview(view) }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = label.sizeThatFits(bounds.size)
        label.frame = CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        let y = bounds.midY, gap: CGFloat = 8, margin: CGFloat = 16, line = 1 / traitCollection.displayScale
        left.frame = CGRect(x: margin, y: y, width: max(0, label.frame.minX - gap - margin), height: line)
        right.frame = CGRect(x: label.frame.maxX + gap, y: y, width: max(0, bounds.width - margin - label.frame.maxX - gap), height: line)
    }
}

/// Which character of a wrapped text is at a point: TextKit built only when a tap asks.
enum LinkHit {
    static func characterIndex(at point: CGPoint, in text: NSAttributedString, size: CGSize) -> Int {
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: size)
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        let glyph = manager.glyphIndex(for: point, in: container)
        guard manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(point) else { return NSNotFound }
        return manager.characterIndexForGlyph(at: glyph)
    }
}

private extension UIColor {
    /// This colour moved `amount` (0–1) of the way to `other`.
    func blended(with other: UIColor, by amount: CGFloat) -> UIColor {
        var (r1, g1, b1, a1, r2, g2, b2, a2): (CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0, 0, 0, 0, 0)
        getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(red: r1 + (r2 - r1) * amount, green: g1 + (g2 - g1) * amount, blue: b1 + (b2 - b1) * amount, alpha: a1 + (a2 - a1) * amount)
    }
}

private extension UIColor {
    /// This colour with its brightness lowered by `amount` (0–1).
    func darkened(by amount: CGFloat) -> UIColor {
        var (hue, saturation, brightness, alpha): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        guard getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else { return self }
        return UIColor(hue: hue, saturation: saturation, brightness: brightness * (1 - amount), alpha: alpha)
    }
}
