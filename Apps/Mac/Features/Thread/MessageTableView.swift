import AppKit

/// The chat's table. A two-finger swipe to the right on a message answers it, as on the iPhone:
/// the message follows the fingers, a round arrow appears where it was, and past the threshold the
/// trackpad ticks; letting go there replies. A vertical swipe scrolls as ever.
final class MessageTableView: NSTableView {
    static let threshold: CGFloat = 64

    /// Whether the message in a row can be answered.
    var canReply: ((Int) -> Bool)?
    var reply: ((Int) -> Void)?
    /// The user scrolls (or swipes) with a wheel or the trackpad.
    var onScrollWheel: (() -> Void)?

    private enum Gesture { case undecided(dx: CGFloat, dy: CGFloat), scrolling, swiping(row: Int, cell: MessageCellView, distance: CGFloat) }
    private var gesture: Gesture?
    private var armed = false

    /// Space shows the selected message's photo, video or file in Quick Look, and hides it again,
    /// as in Finder: the responder action for it goes up the chain, to the chat.
    override func keyDown(with event: NSEvent) {
        guard event.charactersIgnoringModifiers == " ", event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
              tryToPerform(#selector(quickLookPreviewItems(_:)), with: self) else { return super.keyDown(with: event) }
    }

    override func scrollWheel(with event: NSEvent) {
        onScrollWheel?()
        // a mouse wheel, or the momentum after a swipe that answered: nothing to decide.
        guard event.hasPreciseScrollingDeltas else { return super.scrollWheel(with: event) }
        if !event.momentumPhase.isEmpty {
            if case .swiping = gesture { return }
            return super.scrollWheel(with: event)
        }
        // the fingers' own direction, whatever the scrolling direction setting.
        let dx = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
        let dy = event.scrollingDeltaY
        switch event.phase {
        case .began:
            gesture = .undecided(dx: dx, dy: dy)
            armed = false
            super.scrollWheel(with: event)
        case .changed:
            switch gesture {
            case .undecided(let x, let y)?:
                let (sumX, sumY) = (x + dx, y + dy)
                guard max(abs(sumX), abs(sumY)) > 6 else { gesture = .undecided(dx: sumX, dy: sumY); return super.scrollWheel(with: event) }
                let point = convert(event.locationInWindow, from: nil)
                let index = row(at: point)
                if sumX > 0, abs(sumX) > abs(sumY) * 1.5, index >= 0, canReply?(index) == true,
                   let cell = view(atColumn: 0, row: index, makeIfNecessary: false) as? MessageCellView {
                    gesture = .swiping(row: index, cell: cell, distance: sumX)
                    follow(cell, sumX)
                } else {
                    gesture = .scrolling
                    super.scrollWheel(with: event)
                }
            case .swiping(let index, let cell, let distance)?:
                let moved = max(0, distance + dx)
                gesture = .swiping(row: index, cell: cell, distance: moved)
                follow(cell, moved)
            default:
                super.scrollWheel(with: event)
            }
        case .ended, .cancelled:
            if case .swiping(let index, let cell, _)? = gesture {
                cell.settleSwipe()
                if armed, event.phase == .ended { reply?(index) }
            } else {
                super.scrollWheel(with: event)
            }
            gesture = nil
        default:
            super.scrollWheel(with: event)
        }
    }

    /// Follows the fingers to the threshold, then resists; ticks once on crossing it.
    private func follow(_ cell: MessageCellView, _ distance: CGFloat) {
        let shown = distance <= Self.threshold ? distance : Self.threshold + (distance - Self.threshold) * 0.25
        cell.setSwipe(shown, progress: min(1, distance / Self.threshold))
        if (distance >= Self.threshold) != armed {
            armed = distance >= Self.threshold
            if armed { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        }
    }
}

/// The chat's clip view. While an update goes in, the place the chat moved it to holds, even past
/// the end of the rows still to come (`constrainBoundsRect(_:)`): the table then lays out only the
/// rows that will be on screen there, not those at a place the clip was pulled back to meanwhile.
final class MessageClipView: NSClipView {
    var holdsPlace = false

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        holdsPlace ? proposedBounds : super.constrainBoundsRect(proposedBounds)
    }
}
