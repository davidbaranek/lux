import AppKit

extension NSView {
    /// Fades in, or out and then hides. AppKit hit-tests a view whatever its alpha, so a view
    /// faded to nothing would still take the clicks meant for what is under it: one that is not
    /// shown is hidden. The newest call wins: one shown again while it fades out stays.
    func fade(in shows: Bool, duration: TimeInterval = 0.25) {
        if shows {
            if isHidden {
                alphaValue = 0
                isHidden = false
            }
            guard alphaValue < 1 else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                animator().alphaValue = 1
            }
        } else {
            guard !isHidden else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                animator().alphaValue = 0
            } completionHandler: { [weak self] in
                // the animator set the alpha it goes to: 1 here means shown again since.
                MainActor.assumeIsolated { if self?.alphaValue == 0 { self?.isHidden = true } }
            }
        }
    }
}
