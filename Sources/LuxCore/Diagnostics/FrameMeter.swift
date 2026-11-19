import CoreGraphics
import Foundation

/// Counts late frames while a benchmark scrolls (launch argument `-LuxBenchmark`): a frame is
/// late (a hitch) when it came more than half a frame after it was due. Reports the hitch time
/// ratio as Apple defines it: milliseconds of hitches per second of scrolling.
@MainActor
public final class FrameMeter {
    private var last: CFTimeInterval?
    private var start: CFTimeInterval?
    private var frames = 0
    private var hitches = 0
    private var hitchTime: CFTimeInterval = 0
    private var worst: CFTimeInterval = 0
    /// Where the list was at the last frame, the frames it moved in and how far: for a span in
    /// which nobody scrolls it (a chat opening), so any of it moved by itself.
    private var place: CGFloat?
    private var moving = 0
    private var travel: CGFloat = 0

    public init() {}

    /// One frame: when it was shown, and how long a frame lasts on this display. `place`: where
    /// the list is (how far its newest row is below the screen), in a span nobody scrolls it.
    public func frame(at timestamp: CFTimeInterval, duration: CFTimeInterval, place: CGFloat? = nil) {
        defer { last = timestamp }
        if let place {
            if let before = self.place, abs(place - before) > 0.5 {
                moving += 1
                travel += abs(place - before)
            }
            self.place = place
        }
        guard let last else { start = timestamp; return }
        frames += 1
        let late = (timestamp - last) - duration
        if late > duration / 2 {
            hitches += 1
            hitchTime += late
            worst = max(worst, timestamp - last)
        }
    }

    public func report(_ name: String) {
        let seconds = (last ?? 0) - (start ?? 0)
        let ratio = seconds > 0 ? hitchTime * 1000 / seconds : 0
        Log.metrics.notice("""
            benchmark \(name, privacy: .public): \(self.frames, privacy: .public) frames in \(seconds, format: .fixed(precision: 2), privacy: .public) s, \
            \(self.hitches, privacy: .public) hitches, hitch ratio \(ratio, format: .fixed(precision: 1), privacy: .public) ms/s, \
            worst frame \(self.worst * 1000, format: .fixed(precision: 1), privacy: .public) ms, footprint \(Signposts.footprintMB(), format: .fixed(precision: 1), privacy: .public) MB
            """)
        guard place != nil else { return }
        Log.metrics.notice("""
            benchmark \(name, privacy: .public): the list moved by itself in \(self.moving, privacy: .public) frames, \
            \(Double(self.travel), format: .fixed(precision: 0), privacy: .public) points
            """)
    }
}
