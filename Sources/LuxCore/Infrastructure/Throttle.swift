import Foundation

/// Runs the newest scheduled work at most once per interval, and never two at once.
@MainActor
final class Throttle {
    private let interval: Duration
    private var pending: (() async -> Void)?
    private var running = false

    init(interval: Duration) { self.interval = interval }

    func schedule(_ work: @escaping () async -> Void) {
        pending = work
        guard !running else { return }
        running = true
        Task {
            while let work = pending {
                pending = nil
                await work()
                try? await Task.sleep(for: interval)
            }
            running = false
        }
    }
}
