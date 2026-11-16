import Foundation

/// Runs the newest scheduled work at most once per interval, and never two at once.
@MainActor
final class Throttle {
    private let interval: Duration
    private var pending: (() async -> Void)?
    /// The runs, one after another: they end with the throttle.
    private var running: Task<Void, Never>?

    init(interval: Duration) { self.interval = interval }

    deinit { running?.cancel() }

    func schedule(_ work: @escaping () async -> Void) {
        pending = work
        guard running == nil else { return }
        let interval = self.interval
        running = Task { [weak self] in
            while !Task.isCancelled, let work = self?.next() {
                await work()
                try? await Task.sleep(for: interval)
            }
            self?.running = nil
        }
    }

    private func next() -> (() async -> Void)? {
        defer { pending = nil }
        return pending
    }
}
