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
