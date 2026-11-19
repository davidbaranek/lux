import CoreGraphics

/// Where a chat's list is scrolled, the same on both platforms: a top-down content of `contentHeight`
/// seen through `height` points, from `offset` (the content's y at the view's top edge), with
/// `top` and `bottom` of it covered (the bar above, the composer floating below).
public struct ScrollGeometry: Sendable, Equatable {
    public var offset: CGFloat
    public var height: CGFloat
    public var contentHeight: CGFloat
    public var top: CGFloat
    public var bottom: CGFloat

    public init(offset: CGFloat, height: CGFloat, contentHeight: CGFloat, top: CGFloat, bottom: CGFloat) {
        self.offset = offset
        self.height = height
        self.contentHeight = contentHeight
        self.top = top
        self.bottom = bottom
    }

    /// The height the reader sees between the bar and the composer.
    public var visible: CGFloat { height - top - bottom }

    /// The lowest and highest offsets: the content's top under the bar, its end over the composer.
    public var range: ClosedRange<CGFloat> {
        let lowest = -top
        return lowest...max(lowest, contentHeight + bottom - height)
    }

    /// How far the newest message is below the screen.
    public var fromBottom: CGFloat { contentHeight + bottom - offset - height }

    /// The reader is at the newest message (or within a few points of it).
    public var isAtBottom: Bool { fromBottom <= 40 }
    /// Within a few screens of the bottom: newer messages of a jump's rows are asked for.
    public var nearsBottom: Bool { fromBottom < height * 3 }
    /// The offset that shows the bottom.
    public var bottomOffset: CGFloat { offset + fromBottom }

    /// A screen or more above the newest message: the way back is offered.
    public var isScreenAboveBottom: Bool { fromBottom > height }

    /// Older messages are asked for three screens before the top: they are there before the reader is.
    public var nearsTop: Bool { offset < height * 3 }

    /// A row ending at `maxY` is above what the reader sees.
    public func isAbove(_ maxY: CGFloat) -> Bool { maxY <= offset + top }

    /// Where a chat opens whose first unread message starts at `marker`: there, under the bar,
    /// when more than a screen of messages follows it; nil, at the newest message.
    public func opening(atUnread marker: CGFloat) -> CGFloat? {
        contentHeight - marker > visible ? marker - top : nil
    }
}

/// Where an update leaves a chat's list: decided once per update by the presenter, applied once
/// by the screen right after its snapshot. Nothing else moves the list. Only following new messages
/// at the bottom animates, as Messages does; everything else (a jump, rows coming in) is put in
/// place at once.
public enum ScrollIntent: Sendable, Equatable {
    /// Where it is.
    case none
    /// At the newest message; `animated`: a new message slides the list up to it.
    case bottom(animated: Bool)
    /// The row starts `top` points below the list's offset, where the reader saw it (rows coming
    /// in above it, a new width, the rows switching back to live).
    case keep(String, top: CGFloat)
    /// The row in the middle of what the reader sees (a jump to it).
    case centre(String)
    /// At the first unread message, under the bar, when more than a screen follows it; else at
    /// the newest (a chat opening).
    case firstUnread(String)

    /// The list moves there with an animation.
    public var isAnimated: Bool { self == .bottom(animated: true) }
}

extension ScrollGeometry {
    /// The offset `intent` asks for once the rows `ids`, `height` points each, are stacked from
    /// `lead` points down, with `trail` points after them: where the list goes before an update's
    /// rows are in, so the list lays out only the rows that will be on screen there.
    public func offset(for intent: ScrollIntent, stacking ids: [String], height: (String) -> CGFloat,
                       lead: CGFloat = 0, trail: CGFloat = 0) -> CGFloat? {
        let total = ids.reduce(lead + trail) { $0 + height($1) }
        var stacked = self
        stacked.contentHeight = total
        return stacked.offset(for: intent) { id in
            guard let at = ids.firstIndex(of: id) else { return nil }
            let minY = ids[..<at].reduce(lead) { $0 + height($1) }
            return (minY, minY + height(id))
        }
    }

    /// The offset `intent` asks for, within the content; nil: the list stays (no intent, or its
    /// row is not in the list). `rowSpan`: a row's top and bottom in the content.
    public func offset(for intent: ScrollIntent, rowSpan: (String) -> (minY: CGFloat, maxY: CGFloat)?) -> CGFloat? {
        let range = range
        switch intent {
        case .none:
            return nil
        case .bottom:
            return range.upperBound
        case .keep(let id, let top):
            return rowSpan(id).map { min(max($0.minY - top, range.lowerBound), range.upperBound) }
        case .centre(let id):
            return rowSpan(id).map { JumpPlan(toRowFrom: $0.minY, to: $0.maxY, in: self).end }
        case .firstUnread(let id):
            return rowSpan(id).flatMap { opening(atUnread: $0.minY) } ?? range.upperBound
        }
    }
}

/// How the chat glides to a message (a quoted one, the first unread): its middle to the middle of
/// what the reader sees, as far as the content allows. A far message is first brought to a screen
/// away (`start`), so the glide is always one screen long at most.
public struct JumpPlan: Sendable, Equatable {
    /// Where the chat moves at once, before gliding; nil: it glides from where it is.
    public var start: CGFloat?
    /// Where the glide ends.
    public var end: CGFloat

    public init(start: CGFloat?, end: CGFloat) {
        self.start = start
        self.end = end
    }

    /// The plan for a message whose row spans `minY` to `maxY` in the content.
    public init(toRowFrom minY: CGFloat, to maxY: CGFloat, in geometry: ScrollGeometry) {
        let range = geometry.range, visible = geometry.visible
        end = min(max((minY + maxY) / 2 - geometry.top - visible / 2, range.lowerBound), range.upperBound)
        let current = geometry.offset
        start = abs(end - current) > visible ? end + (end < current ? visible : -visible) : nil
    }

    /// The chat is already there: nothing glides, the message only flashes.
    public func arrived(from offset: CGFloat) -> Bool { abs(end - (start ?? offset)) < 1 }
}
