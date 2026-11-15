import CoreGraphics
import Foundation
import os

/// The kinds of text in a message row; each platform measures them with its own fonts.
public enum TextRole: Sendable {
    case sender, quote, body, footer, reactions
    /// The sender's name over a group of plain rows (`ChatStyle.plain`).
    case author
    /// The line over a plain reply: the answered message's sender and text, on one line.
    case reply
    /// A file's name in its row.
    case fileName
    /// A shared post's card: its title (at most two lines), its caption, and "Show more".
    case postTitle, postText, postMore
}

/// Measures text the way the platform will draw it. Called off the main thread.
public protocol TextMeasuring: Sendable {
    /// The size of `text` in `role`'s font, wrapped at `width`.
    func size(of text: String, role: TextRole, width: CGFloat) -> CGSize
    /// The size of a message's text with its formatting (bold, code, quotes), wrapped at `width`.
    func size(ofBody message: MessageItem, width: CGFloat) -> CGSize
}

extension TextMeasuring {
    public func size(ofBody message: MessageItem, width: CGFloat) -> CGSize {
        size(of: message.body, role: .body, width: width)
    }
}

/// Spacing of a message row, in points.
public struct BubbleMetrics: Sendable, Equatable {
    public var sideMargin: CGFloat = 16
    /// The widest a bubble may be, as a share of the row.
    public var maxBubbleShare: CGFloat = 0.78
    public var paddingX: CGFloat = 12
    public var paddingY: CGFloat = 7
    /// Between the parts inside a bubble (quote, photo, text, time).
    public var innerSpacing: CGFloat = 4
    /// Between the sender, the bubble and the reactions.
    public var outerSpacing: CGFloat = 2
    public var photoWidth: CGFloat = 240
    public var photoHeights: ClosedRange<CGFloat> = 120...320
    /// A file's row: its symbol in a square, its name and size beside it.
    public var fileHeight: CGFloat = 44
    public var fileIconSide: CGFloat = 36
    public var fileGap: CGFloat = 10
    /// Space above the first message of a run, and above every other one.
    public var groupGap: CGFloat = 8
    public var runGap: CGFloat = 1
    /// A group's incoming messages leave a column for the sender's picture, shown at the end of
    /// each run of their messages (as Messages does).
    public var avatarSide: CGFloat = 28
    public var avatarGap: CGFloat = 8
    public var reactionPaddingX: CGFloat = 8
    public var reactionPaddingY: CGFloat = 3
    /// The day separator's and the unread marker's height (each with its own text).
    public var markerHeight: CGFloat = 32
    /// A shared post's caption shows this many lines until the user unfolds it.
    public var postLines = 4
    /// Plain rows (`ChatStyle.plain`): the sender's picture beside their name, their messages in
    /// a column after it.
    public var plainAvatarSide: CGFloat = 36
    public var plainAvatarGap: CGFloat = 12
    /// A shared post's card in a plain row is no wider than this.
    public var plainCardWidth: CGFloat = 400
    /// Space above a plain group's name, and above every other of its rows (besides their bands).
    public var plainGroupGap: CGFloat = 10
    public var plainRunGap: CGFloat = 0
    /// The band behind a plain row (for a tap, a menu, a jump) reaches this far above and below its
    /// parts, and stays this far from the row's sides.
    public var plainBand: CGFloat = 5
    public var plainBandInset: CGFloat = 6
    /// A plain reply's line: the answered sender's small picture, and the line from the sender's
    /// picture up to it.
    public var replyAvatarSide: CGFloat = 16
    public var replyGap: CGFloat = 4

    public init() {}
}

/// How a chat draws its messages: in bubbles, one's own on the trailing side, or as plain rows
/// under their sender's picture and name, across the whole width (as Discord and Slack do).
public enum ChatStyle: String, Sendable, CaseIterable {
    case bubbles, plain
}

/// Where every part of a message row goes, measured once off the main thread (as Signal's
/// conversation view does), so a cell only assigns frames and the list knows every height.
/// Rects are in the row's coordinates, top-left origin; the inner parts are in the bubble's.
public struct MessageLayout: Sendable, Equatable {
    /// The parts of a bubble, top to bottom.
    private enum Part { case quote, photo, file, postTitle, postText, postMore, body, footer }

    public var height: CGFloat
    public var style: ChatStyle = .bubbles
    public var sender: CGRect?
    /// A plain group's time, after its sender's name.
    public var time: CGRect?
    /// Over a plain reply, in the row's coordinates: the answered message's sender and text on one
    /// line, their picture before it, and the link drawn from above the sender's picture up and
    /// round to it (from this rect's bottom-left corner to its top-right one).
    public var reply: CGRect?
    public var replyAvatar: CGRect?
    public var replyLink: CGRect?
    /// The message's content: a bubble's ground, or a plain row's parts (with no ground).
    public var bubble: CGRect
    public var quote: CGRect?
    public var photo: CGRect?
    /// An album's tiles, in the photo's coordinates, in order.
    public var albumTiles: [CGRect] = []
    /// A file's row (symbol, name, size); a sound's too.
    public var file: CGRect?
    public var body: CGRect?
    /// A shared post's card across the bubble (its media, title, caption and "Show more"), set
    /// apart from the message's own text; its parts in the bubble's coordinates.
    public var post: CGRect?
    public var postTitle: CGRect?
    public var postText: CGRect?
    public var postMore: CGRect?
    /// The card's caption shows only its first lines (`BubbleMetrics.postLines`).
    public var postFolded = false
    public var footer: CGRect?
    public var reactions: CGRect?
    /// The sender's picture, level with the bubble's bottom; nil for own messages, outside groups,
    /// and inside a run. A plain group's, beside its name, own messages too.
    public var avatar: CGRect?
    /// A plain row's band across the whole row, behind its parts: it takes a tap, lifts for the
    /// menu, flashes after a jump and darkens while the details show. Nil for a bubble.
    public var band: CGRect?
    /// "Today", "Yesterday"… above the first message of a day, across the whole row.
    public var day: CGRect?
    /// "New messages" above the first unread message, across the whole row.
    public var unreadMarker: CGRect?
    /// "Read by Anna, Petr" under the message the others last read.
    public var readers: CGRect?
    /// "WhatsApp · Today 14:32" under a message the user tapped.
    public var detail: CGRect?

    public static func make(_ message: MessageItem, showsSender: Bool, isFirstUnread: Bool = false, style: ChatStyle = .bubbles,
                            width: CGFloat, metrics m: BubbleMetrics, measure: some TextMeasuring) -> MessageLayout {
        switch style {
        case .bubbles: bubbled(message, showsSender: showsSender, isFirstUnread: isFirstUnread, width: width, metrics: m, measure: measure)
        case .plain: plain(message, showsSender: showsSender, isFirstUnread: isFirstUnread, width: width, metrics: m, measure: measure)
        }
    }

    /// The parts inside a message's bubble (or a plain row's content), in its coordinates, with
    /// the bubble's size; at most `maxBubble` wide. `padded`: the parts keep the bubble's padding
    /// (a plain row's parts have none, but a card's).
    private static func content(_ message: MessageItem, maxBubble: CGFloat, padded: Bool, timeAtLeading: Bool,
                                quoteInside: Bool = true, metrics m: BubbleMetrics, measure: some TextMeasuring) -> MessageLayout {
        // a photo or a video alone is the bubble itself, as Messages draws it: no padding round it.
        let (padX, padY) = message.isMediaOnly || !padded ? (CGFloat(0), CGFloat(0)) : (m.paddingX, m.paddingY)
        // a shared post is a card the width of its media, the media edge to edge at its top.
        let post = message.postCard
        let edgeMedia = post != nil && message.photo != nil && message.album.count <= 1 && message.quote == nil
        let maxInner = edgeMedia ? min(m.photoWidth, maxBubble) - 2 * padX : maxBubble - 2 * padX
        var parts: [(kind: Part, size: CGSize)] = []
        if quoteInside, let quote = message.quoteText { parts.append((.quote, measure.size(of: quote, role: .quote, width: maxInner))) }
        var albumTiles: [CGRect] = []
        if message.album.count > 1 {
            let grid = Self.albumGrid(count: message.album.count, width: min(m.photoWidth, maxInner))
            albumTiles = grid.tiles
            parts.append((.photo, grid.size))
        } else if let photo = message.photo {
            let ratio = photo.width > 0 && photo.height > 0 ? CGFloat(photo.height) / CGFloat(photo.width) : 0.75
            let height = min(max(m.photoWidth * ratio, m.photoHeights.lowerBound), m.photoHeights.upperBound)
            parts.append((.photo, CGSize(width: edgeMedia ? maxInner + 2 * padX : min(m.photoWidth, maxInner), height: height)))
        }
        if let file = message.file {
            let besideIcon = maxInner - m.fileIconSide - m.fileGap
            let text = max(measure.size(of: file.name, role: .fileName, width: besideIcon).width,
                           measure.size(of: file.detailText, role: .footer, width: besideIcon).width)
            parts.append((.file, CGSize(width: min(maxInner, ceil(m.fileIconSide + m.fileGap + text)), height: m.fileHeight)))
        }
        var postFolded = false
        if let post {
            if let title = post.title { parts.append((.postTitle, measure.size(of: title, role: .postTitle, width: maxInner))) }
            if let text = post.description {
                var size = measure.size(of: text, role: .postText, width: maxInner)
                // the first lines' height, measured as the platform draws lines.
                let lines = Array(repeating: "X", count: m.postLines).joined(separator: "\n")
                let folded = measure.size(of: lines, role: .postText, width: maxInner).height
                // a caption longer than its first lines folds, with "Show more" (or "Show less") under it.
                if size.height > folded + 1 {
                    if !message.showsWholePost {
                        size.height = folded
                        postFolded = true
                    }
                    parts.append((.postText, size))
                    let more = message.showsWholePost ? MessageItem.showLessText : MessageItem.showMoreText
                    parts.append((.postMore, measure.size(of: more, role: .postMore, width: maxInner)))
                } else {
                    parts.append((.postText, size))
                }
            }
        }
        if !message.body.isEmpty { parts.append((.body, measure.size(ofBody: message, width: maxInner))) }
        if let footer = message.footerText { parts.append((.footer, measure.size(of: footer, role: .footer, width: maxInner))) }

        let contentWidth = parts.map { $0.kind == .photo && edgeMedia ? $0.size.width - 2 * padX : $0.size.width }.max() ?? 0
        let bubbleWidth = ceil(contentWidth + 2 * padX)
        var layout = MessageLayout(height: 0, bubble: .zero)
        layout.albumTiles = albumTiles
        layout.postFolded = postFolded
        let isPostPart: (Part) -> Bool = { [.postTitle, .postText, .postMore].contains($0) || ($0 == .photo && edgeMedia) }
        var y = padY
        var postBottom: CGFloat?
        for (index, part) in parts.enumerated() {
            let isLast = index == parts.count - 1
            if part.kind == .photo, edgeMedia {
                layout.photo = CGRect(x: 0, y: 0, width: bubbleWidth, height: part.size.height)
                y = part.size.height + (isLast ? 0 : padY)
            } else {
                // the time sits at the bubble's trailing edge; the rest at its leading edge.
                let x = part.kind == .footer && !timeAtLeading ? bubbleWidth - max(padX, 4) - part.size.width : padX
                let rect = CGRect(origin: CGPoint(x: x, y: y), size: part.size)
                switch part.kind {
                case .quote: layout.quote = rect
                case .photo: layout.photo = rect
                case .file: layout.file = rect
                case .postTitle: layout.postTitle = rect
                case .postText: layout.postText = rect
                case .postMore: layout.postMore = rect
                case .body: layout.body = rect
                case .footer: layout.footer = rect
                }
                y += part.size.height + (isLast ? 0 : m.innerSpacing)
            }
            // the card ends with its last part; the message's own text starts below it.
            if isPostPart(part.kind), isLast || !isPostPart(parts[index + 1].kind) {
                let bottom = isLast ? y + padY : y - m.innerSpacing + padY
                postBottom = bottom
                if !isLast { y = bottom + padY }
            }
        }
        let bubbleHeight = ceil(max(y + padY, postBottom ?? 0))
        if post != nil, let postBottom {
            layout.post = CGRect(x: 0, y: 0, width: bubbleWidth, height: min(ceil(postBottom), bubbleHeight))
        }
        layout.bubble.size = CGSize(width: bubbleWidth, height: bubbleHeight)
        return layout
    }

    /// The day separator's and the unread marker's rows above a message, from the row's top;
    /// returns where the message starts.
    private mutating func placeMarkers(_ message: MessageItem, isFirstUnread: Bool, width: CGFloat, metrics m: BubbleMetrics) -> CGFloat {
        var top: CGFloat = 0
        if message.startsDay || message.startsTimeGap {
            day = CGRect(x: 0, y: top + 4, width: width, height: m.markerHeight)
            top += m.markerHeight + 4
        }
        if isFirstUnread {
            unreadMarker = CGRect(x: 0, y: top + 4, width: width, height: m.markerHeight)
            top += m.markerHeight + 4
        }
        return top
    }

    /// What goes under a message, each line at `x(width)`: its reactions, its details, who read it.
    private mutating func placeUnder(_ message: MessageItem, showsSender: Bool, top start: CGFloat, maxWidth: CGFloat,
                                     metrics m: BubbleMetrics, measure: some TextMeasuring, x: (CGFloat) -> CGFloat) -> CGFloat {
        var top = start
        if let text = message.reactionsText {
            let size = measure.size(of: text, role: .reactions, width: maxWidth)
            let pill = CGSize(width: ceil(size.width + 2 * m.reactionPaddingX), height: ceil(size.height + 2 * m.reactionPaddingY))
            top += m.outerSpacing
            reactions = CGRect(x: x(pill.width), y: top, width: pill.width, height: pill.height)
            top += pill.height
        }
        if let text = message.detailText {
            let size = measure.size(of: text, role: .footer, width: maxWidth)
            top += m.outerSpacing
            detail = CGRect(x: x(size.width), y: top, width: size.width, height: size.height)
            top += size.height
        }
        if let text = message.readersText(inGroup: showsSender) {
            let size = measure.size(of: text, role: .footer, width: maxWidth)
            top += m.outerSpacing
            readers = CGRect(x: x(size.width), y: top, width: size.width, height: size.height)
            top += size.height
        }
        return top
    }

    /// A bubble, one's own at the trailing side, others' at the leading side under their name.
    private static func bubbled(_ message: MessageItem, showsSender: Bool, isFirstUnread: Bool, width: CGFloat,
                                metrics m: BubbleMetrics, measure: some TextMeasuring) -> MessageLayout {
        // a group's incoming messages are indented by the picture column.
        let indent = showsSender && !message.isOwn ? m.avatarSide + m.avatarGap : 0
        let maxBubble = floor(min(width * m.maxBubbleShare, width - 2 * m.sideMargin - indent))
        var layout = content(message, maxBubble: maxBubble, padded: true, timeAtLeading: false, metrics: m, measure: measure)
        let (bubbleWidth, bubbleHeight) = (layout.bubble.width, layout.bubble.height)

        func aligned(_ w: CGFloat) -> CGFloat { message.isOwn ? width - m.sideMargin - w : m.sideMargin + indent }
        var top = layout.placeMarkers(message, isFirstUnread: isFirstUnread, width: width, metrics: m)
        top += message.startsGroup ? m.groupGap : m.runGap
        if showsSender, !message.isOwn, message.startsGroup {
            let size = measure.size(of: message.senderName, role: .sender, width: maxBubble)
            // level with the text inside the bubble, not with the bubble's edge.
            layout.sender = CGRect(x: aligned(size.width) + m.paddingX, y: top, width: size.width, height: size.height)
            top += size.height + m.outerSpacing
        }
        layout.bubble = CGRect(x: aligned(bubbleWidth), y: top, width: bubbleWidth, height: bubbleHeight)
        if indent > 0, message.endsGroup {
            layout.avatar = CGRect(x: m.sideMargin, y: layout.bubble.maxY - m.avatarSide, width: m.avatarSide, height: m.avatarSide)
        }
        top += bubbleHeight
        top = layout.placeUnder(message, showsSender: showsSender, top: top, maxWidth: maxBubble, metrics: m, measure: measure, x: aligned)
        layout.height = ceil(top)
        return layout
    }

    /// A plain row: the first of a sender's run under their picture, name and time, every message
    /// in the column after the picture, own ones too, with no bubble round it.
    private static func plain(_ message: MessageItem, showsSender: Bool, isFirstUnread: Bool, width: CGFloat,
                              metrics m: BubbleMetrics, measure: some TextMeasuring) -> MessageLayout {
        let column = m.sideMargin + m.plainAvatarSide + m.plainAvatarGap
        let available = max(floor(width - column - m.sideMargin), 1)
        // a shared post keeps its card, which reads best at a card's width.
        let maxContent = message.postCard == nil ? available : min(available, m.plainCardWidth)
        // a reply's quote is a line over its header (which a reply always has), not in its content.
        var layout = content(message, maxBubble: maxContent, padded: message.postCard != nil, timeAtLeading: true,
                             quoteInside: false, metrics: m, measure: measure)
        layout.style = .plain
        let header = message.startsGroup || message.quote != nil
        var top = layout.placeMarkers(message, isFirstUnread: isFirstUnread, width: width, metrics: m)
        top += (header ? m.plainGroupGap : m.plainRunGap) + m.plainBand
        let bandTop = top - m.plainBand
        if message.quote != nil {
            let line = measure.size(of: "X", role: .reply, width: available).height
            let height = max(line, m.replyAvatarSide)
            layout.replyAvatar = CGRect(x: column, y: top + (height - m.replyAvatarSide) / 2, width: m.replyAvatarSide, height: m.replyAvatarSide)
            let textX = column + m.replyAvatarSide + m.replyGap
            layout.reply = CGRect(x: textX, y: top + (height - line) / 2, width: max(width - m.sideMargin - textX, 0), height: line)
            // from above the sender's picture (two points clear of it) up to the reply's middle, then
            // across to its picture.
            let start = m.sideMargin + m.plainAvatarSide / 2
            let middle = top + height / 2
            layout.replyLink = CGRect(x: start, y: middle, width: column - m.replyGap - start,
                                      height: top + height + m.replyGap - 2 - middle)
            top += height + m.replyGap
        }
        if header {
            let name = measure.size(of: message.senderName, role: .author, width: available)
            let time = measure.size(of: message.headerTimeText, role: .footer, width: available)
            let gap: CGFloat = 6
            let nameWidth = min(name.width, available - time.width - gap)
            layout.sender = CGRect(x: column, y: top, width: max(nameWidth, 0), height: name.height)
            // the time on the name's line, their bottoms level.
            layout.time = CGRect(x: column + max(nameWidth, 0) + gap, y: top + name.height - time.height - 1,
                                 width: time.width, height: time.height)
            layout.avatar = CGRect(x: m.sideMargin, y: top, width: m.plainAvatarSide, height: m.plainAvatarSide)
            top += name.height + m.outerSpacing
        }
        layout.bubble.origin = CGPoint(x: column, y: top)
        top += layout.bubble.height
        top = layout.placeUnder(message, showsSender: showsSender, top: top, maxWidth: available, metrics: m, measure: measure) { _ in column }
        // a run's single line is no shorter than the picture beside it.
        if let avatar = layout.avatar, message.endsGroup { top = max(top, avatar.maxY) }
        top += m.plainBand
        layout.band = CGRect(x: m.plainBandInset, y: bandTop, width: width - 2 * m.plainBandInset, height: top - bandTop)
        layout.height = ceil(top)
        return layout
    }
}

extension MessageLayout {
    /// The link from a plain reply's sender up to its quote, in `replyLink`'s own coordinates (top
    /// left origin): up its leading edge, round a corner, across its top. Stroke it `lineWidth`
    /// wide; it is inset by half of that so the stroke stays inside.
    public static func replyLinkPath(size: CGSize, lineWidth: CGFloat) -> CGPath {
        let half = lineWidth / 2
        let radius = min(6, size.width - half, size.height - half)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: half, y: size.height))
        path.addLine(to: CGPoint(x: half, y: half + radius))
        path.addArc(tangent1End: CGPoint(x: half, y: half), tangent2End: CGPoint(x: half + radius, y: half), radius: radius)
        path.addLine(to: CGPoint(x: size.width, y: half))
        return path
    }

    /// An album's square tiles: two or four in two columns, the rest in three, two points apart.
    public static func albumGrid(count: Int, width: CGFloat) -> (size: CGSize, tiles: [CGRect]) {
        let gap: CGFloat = 2
        let columns = count == 2 || count == 4 ? 2 : 3
        let side = floor((width - gap * CGFloat(columns - 1)) / CGFloat(columns))
        let rows = (count + columns - 1) / columns
        let tiles = (0..<count).map { index in
            CGRect(x: CGFloat(index % columns) * (side + gap), y: CGFloat(index / columns) * (side + gap), width: side, height: side)
        }
        return (CGSize(width: side * CGFloat(columns) + gap * CGFloat(columns - 1), height: side * CGFloat(rows) + gap * CGFloat(rows - 1)), tiles)
    }
}

extension MessageItem {
    /// What a row shows, in one place, so the layout measures exactly what the cell draws.
    public var quoteText: String? {
        quote.map { "↩︎ " + ($0.senderName.isEmpty ? $0.text : "\($0.senderName): \($0.text)") }
    }

    /// After a plain group's sender's name: the time of its first message ("14:32").
    public var headerTimeText: String { TimeText.message(date) }

    /// Above the first message of a day, or after a pause: the day and the time ("Today 14:32").
    public var separatorText: String {
        TimeText.day(date) + " " + TimeText.message(date)
    }

    /// What is not plain about the message: "Edited", "Sending…", "Uploading 40 %", "Not sent";
    /// nil for a sent message. Its time shows above a pause, and in its details on a tap.
    public var footerText: String? {
        guard let footer else { return nil }
        var parts: [String] = []
        if footer.isEdited { parts.append(String(localized: "Edited")) }
        switch footer.status {
        case .sending: parts.append(String(localized: "Sending…"))
        case .uploading(let progress): parts.append(String(localized: "Uploading \(Int(progress * 100)) %"))
        case .failed: parts.append(String(localized: "Not sent"))
        case nil: break
        }
        return parts.joined(separator: " · ")
    }

    /// "Read by Anna, Petr" in a group, "Read" in a conversation of two; nil when nobody has.
    public func readersText(inGroup: Bool) -> String? {
        guard !readers.isEmpty else { return nil }
        guard inGroup else { return String(localized: "Read") }
        let names = readers.map { $0.name.split(separator: " ").first.map(String.init) ?? $0.name }
        let shown = names.prefix(3).joined(separator: ", ")
        return names.count > 3 ? String(localized: "Read by \(shown) and \(names.count - 3) more") : String(localized: "Read by \(shown)")
    }

    /// Under a tapped message: its network (in a merged chat) and its full time.
    public var detailText: String? {
        guard showsDetail else { return nil }
        let time = date.formatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute())
        return network.map { Networks.name($0) + " · " + time } ?? time
    }

    /// Only a photo or a video: drawn without a bubble round it.
    public var isMediaOnly: Bool { photo != nil && body.isEmpty && quote == nil && file == nil && postCard == nil }

    /// A shared post with something to tell (its title or caption): a card; nil while the server
    /// has not read its page, or when it has nothing to say.
    public var postCard: SharedPost? {
        shared.flatMap { $0.title != nil || $0.description != nil ? $0 : nil }
    }

    /// Under a folded caption, and under an unfolded one.
    public static let showMoreText = String(localized: "Show more")
    public static let showLessText = String(localized: "Show less")

    /// A video's length on its picture ("1:05"); nil for a photo.
    public var durationText: String? { video.map { TimeText.duration($0.duration) } }

    public var reactionsText: String? {
        reactions.isEmpty ? nil : reactions.map { $0.count > 1 ? "\($0.key) \($0.count)" : $0.key }.joined(separator: "  ")
    }
}

extension MessageItem.File {
    /// Under a file's name: "PDF · 180 KB", or a sound's length ("Voice message · 0:12").
    public var detailText: String {
        switch kind {
        case .voice, .audio:
            duration > 0 ? TimeText.duration(duration) : ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        case .document:
            [(name as NSString).pathExtension.uppercased(), size > 0 ? ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) : ""]
                .filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }

    /// The SF Symbol of its kind.
    public var symbol: String {
        switch kind {
        case .voice: "waveform"
        case .audio: "music.note"
        case .document: mimetype.hasPrefix("video/") ? "film" : mimetype == "application/pdf" ? "doc.richtext" : "doc"
        }
    }
}

/// Layouts by message id, kept while the message and the width stay the same (Signal reuses a
/// message's measurement until the message changes). Safe from any thread.
public final class MessageLayoutCache: Sendable {
    private struct Entry {
        var message: MessageItem
        var layout: MessageLayout
    }

    private struct State {
        var width: CGFloat = 0
        var showsSender = false
        var style = ChatStyle.bubbles
        var firstUnread: String?
        var entries: [String: Entry] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    public let metrics: BubbleMetrics

    public init(metrics: BubbleMetrics = BubbleMetrics()) { self.metrics = metrics }

    /// Forget every layout (the text size changed).
    public func reset() { state.withLock { $0.entries = [:] } }

    /// The layouts of `messages` at `width`, measuring only new or changed messages, and the ids
    /// of messages that were there before and look different now. Call off the main thread.
    public func update(_ messages: [MessageItem], showsSender: Bool, firstUnread: String? = nil, style: ChatStyle = .bubbles,
                       width: CGFloat, measure: some TextMeasuring) -> (layouts: [String: MessageLayout], changed: [String]) {
        let previous = state.withLock { current -> [String: Entry] in
            if current.width != width || current.showsSender != showsSender || current.firstUnread != firstUnread || current.style != style {
                current = State(width: width, showsSender: showsSender, style: style, firstUnread: firstUnread)
            }
            return current.entries
        }
        var entries: [String: Entry] = [:]
        entries.reserveCapacity(messages.count)
        var changed: [String] = []
        for message in messages {
            if let old = previous[message.id], old.message == message {
                entries[message.id] = old
                continue
            }
            if previous[message.id] != nil { changed.append(message.id) }
            // string measuring makes temporary Objective-C objects; a worker thread would keep them
            // until its pool drains, which for thousands of messages is many megabytes.
            let layout = autoreleasepool {
                MessageLayout.make(message, showsSender: showsSender, isFirstUnread: message.id == firstUnread, style: style,
                                   width: width, metrics: metrics, measure: measure)
            }
            entries[message.id] = Entry(message: message, layout: layout)
        }
        // messages no longer in the chat leave the cache.
        let kept = entries
        state.withLock { $0.entries = kept }
        return (kept.mapValues(\.layout), changed)
    }
}
