import AppKit
import LuxCore

/// Scrolls a view at a steady speed (as a fast fling does) for 15,000 points (or to its end) and back,
/// one step per display frame, and reports late frames (`FrameMeter`). Only with `-LuxBenchmark`.
@MainActor
final class ScrollBenchmark: NSObject {
    private let scrollView: NSScrollView
    private let name: String
    private let pointsPerSecond: CGFloat
    private let meter = FrameMeter()
    private var link: CADisplayLink?
    private var direction: CGFloat
    private var turns = 0
    /// How far it scrolls before it turns back.
    private let distance: CGFloat = 15_000
    private var travelled: CGFloat = 0
    private var done: (() -> Void)?

    /// `direction`: 1 scrolls down first, -1 up first.
    init(_ scrollView: NSScrollView, name: String, direction: CGFloat, pointsPerSecond: CGFloat = 3_000) {
        self.scrollView = scrollView
        self.name = name
        self.direction = direction
        self.pointsPerSecond = pointsPerSecond
    }

    func run(then done: @escaping () -> Void = {}) {
        self.done = done
        let link = scrollView.displayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func step(_ link: CADisplayLink) {
        let duration = link.targetTimestamp - link.timestamp
        meter.frame(at: link.timestamp, duration: duration)
        let clip = scrollView.contentView
        let inset = scrollView.contentInsets
        let top = -inset.top
        let bottom = max(top, (scrollView.documentView?.frame.height ?? 0) + inset.bottom - clip.bounds.height)
        let delta = pointsPerSecond * duration
        var y = clip.bounds.origin.y + direction * delta
        travelled += delta
        if y <= top || y >= bottom || travelled >= distance {
            travelled = 0
            y = min(max(y, top), bottom)
            direction = -direction
            turns += 1
        }
        clip.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(clip)
        if turns == 2 {
            link.invalidate()
            meter.report(name)
            done?()
        }
    }
}
