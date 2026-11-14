import CoreGraphics
import Foundation
import os

/// The kinds of text in a message row; each platform measures them with its own fonts.
public enum TextRole: Sendable {
    case sender, quote, body, footer, reactions
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

    public init() {}
}

/// Where every part of a message row goes, measured once off the main thread (as Signal's
/// conversation view does), so a cell only assigns frames and the list knows every height.
/// Rects are in the row's coordinates, top-left origin; the inner parts are in the bubble's.
public struct MessageLayout: Sendable, Equatable {
    /// The parts of a bubble, top to bottom.
    private enum Part { case quote, photo, file, postTitle, postText, postMore, body, footer }

    public var height: CGFloat
    public var sender: CGRect?
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
    /// and inside a run.
    public var avatar: CGRect?
    /// "Today", "Yesterday"… above the first message of a day, across the whole row.
    public var day: CGRect?
    /// "New messages" above the first unread message, across the whole row.
    public var unreadMarker: CGRect?
    /// "Read by Anna, Petr" under the message the others last read.
    public var readers: CGRect?
    /// "WhatsApp · Today 14:32" under a message the user tapped.
    public var detail: CGRect?

    public static func make(_ message: MessageItem, showsSender: Bool, isFirstUnread: Bool = false, width: CGFloat,
                            metrics m: BubbleMetrics, measure: some TextMeasuring) -> MessageLayout {
        // a group's incoming messages are indented by the picture column.
        let indent = showsSender && !message.isOwn ? m.avatarSide + m.avatarGap : 0
        let maxBubble = floor(min(width * m.maxBubbleShare, width - 2 * m.sideMargin - indent))
        // a photo or a video alone is the bubble itself, as Messages draws it: no padding round it.
        let (padX, padY) = message.isMediaOnly ? (CGFloat(0), CGFloat(0)) : (m.paddingX, m.paddingY)
        // a shared post is a card the width of its media, the media edge to edge at its top.
        let post = message.postCard
        let edgeMedia = post != nil && message.photo != nil && message.album.count <= 1 && message.quote == nil
        let maxInner = edgeMedia ? min(m.photoWidth, maxBubble) - 2 * padX : maxBubble - 2 * padX
        var parts: [(kind: Part, size: CGSize)] = []
        if let quote = message.quoteText { parts.append((.quote, measure.size(of: quote, role: .quote, width: maxInner))) }
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
                let x = part.kind == .footer ? bubbleWidth - max(padX, 4) - part.size.width : padX
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

        func aligned(_ w: CGFloat) -> CGFloat { message.isOwn ? width - m.sideMargin - w : m.sideMargin + indent }
        var top: CGFloat = 0
        if message.startsDay || message.startsTimeGap {
            layout.day = CGRect(x: 0, y: top + 4, width: width, height: m.markerHeight)
            top += m.markerHeight + 4
        }
        if isFirstUnread {
            layout.unreadMarker = CGRect(x: 0, y: top + 4, width: width, height: m.markerHeight)
            top += m.markerHeight + 4
        }
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
        if let reactions = message.reactionsText {
            let text = measure.size(of: reactions, role: .reactions, width: maxBubble)
            let size = CGSize(width: ceil(text.width + 2 * m.reactionPaddingX), height: ceil(text.height + 2 * m.reactionPaddingY))
            top += m.outerSpacing
            layout.reactions = CGRect(x: aligned(size.width), y: top, width: size.width, height: size.height)
            top += size.height
        }
        if let detail = message.detailText {
            let size = measure.size(of: detail, role: .footer, width: maxBubble)
            top += m.outerSpacing
            layout.detail = CGRect(x: aligned(size.width), y: top, width: size.width, height: size.height)
            top += size.height
        }
        if let readers = message.readersText(inGroup: showsSender) {
            let size = measure.size(of: readers, role: .footer, width: maxBubble)
            top += m.outerSpacing
            layout.readers = CGRect(x: aligned(size.width), y: top, width: size.width, height: size.height)
            top += size.height
        }
        layout.height = ceil(top)
        return layout
    }
}

extension MessageLayout {
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
    public var quoteText: String? { quote.map { "↩︎ " + $0 } }

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
    public func update(_ messages: [MessageItem], showsSender: Bool, firstUnread: String? = nil, width: CGFloat,
                       measure: some TextMeasuring) -> (layouts: [String: MessageLayout], changed: [String]) {
        let previous = state.withLock { current -> [String: Entry] in
            if current.width != width || current.showsSender != showsSender || current.firstUnread != firstUnread {
                current = State(width: width, showsSender: showsSender, firstUnread: firstUnread)
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
                MessageLayout.make(message, showsSender: showsSender, isFirstUnread: message.id == firstUnread, width: width,
                                   metrics: metrics, measure: measure)
            }
            entries[message.id] = Entry(message: message, layout: layout)
        }
        // messages no longer in the chat leave the cache.
        let kept = entries
        state.withLock { $0.entries = kept }
        return (kept.mapValues(\.layout), changed)
    }
}
