import UIKit

/// Drag a message to the right to answer it, as WhatsApp does: the row follows the finger, an
/// arrow appears where it was, and past the threshold a tick of haptics says
/// letting go will reply. One recognizer on the list serves every row.
@MainActor
final class SwipeToReply: NSObject, UIGestureRecognizerDelegate {
    /// How far the row must go before letting go replies.
    static let threshold: CGFloat = 64
    private weak var collectionView: UICollectionView?
    /// Whether the message at an index path can be answered, and answering it.
    private let canReply: (IndexPath) -> Bool
    private let reply: (IndexPath) -> Void
    private var active: (cell: MessageCell, indexPath: IndexPath)?
    private var armed = false
    private let haptics = UIImpactFeedbackGenerator(style: .light)

    init(_ collectionView: UICollectionView, canReply: @escaping (IndexPath) -> Bool, reply: @escaping (IndexPath) -> Void) {
        self.collectionView = collectionView
        self.canReply = canReply
        self.reply = reply
        super.init()
        let pan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
        pan.delegate = self
        collectionView.addGestureRecognizer(pan)
        self.pan = pan
    }

    /// The recognizer, for gestures that must wait for it (the navigation's full-width back swipe).
    private(set) weak var pan: UIPanGestureRecognizer?

    /// Only a mostly horizontal drag to the right, on a message that can be answered: vertical drags
    /// stay with scrolling, and drags elsewhere stay with the back gesture.
    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard let pan = recognizer as? UIPanGestureRecognizer, let collectionView else { return false }
        let velocity = pan.velocity(in: collectionView)
        guard velocity.x > 0, abs(velocity.x) > abs(velocity.y) * 1.5,
              let indexPath = collectionView.indexPathForItem(at: pan.location(in: collectionView)) else { return false }
        return canReply(indexPath)
    }

    @objc private func pan(_ pan: UIPanGestureRecognizer) {
        guard let collectionView else { return }
        switch pan.state {
        case .began:
            guard let indexPath = collectionView.indexPathForItem(at: pan.location(in: collectionView)),
                  let cell = collectionView.cellForItem(at: indexPath) as? MessageCell else { pan.state = .cancelled; return }
            active = (cell, indexPath)
            armed = false
            haptics.prepare()
        case .changed:
            guard let active else { return }
            let distance = max(0, pan.translation(in: collectionView).x)
            // follows the finger to the threshold, then resists.
            let shown = distance <= Self.threshold ? distance : Self.threshold + (distance - Self.threshold) * 0.25
            active.cell.setSwipe(shown, progress: min(1, distance / Self.threshold))
            if (distance >= Self.threshold) != armed {
                armed.toggle()
                if armed { haptics.impactOccurred() }
            }
        case .ended, .cancelled, .failed:
            guard let active else { return }
            self.active = nil
            UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0) {
                active.cell.setSwipe(0, progress: 0)
            }
            if pan.state == .ended, armed { reply(active.indexPath) }
            armed = false
        default: break
        }
    }
}
