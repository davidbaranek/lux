import LuxCore
import Testing

/// What a model announced, for a test to await: each announcement wakes the waiting test, which
/// checks its condition again. Nothing polls. (`Tests/LuxCoreTests/Changes.swift` in small: the
/// package's test target is not linked into the app's.)
@MainActor
final class Changes {
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func send() {
        let woken = waiting
        waiting = []
        for continuation in woken { continuation.resume() }
    }

    /// Returns once `done` holds, checked at each announcement. Once `limit` passed without it,
    /// the test stops here, as at a failed `#require`.
    func until(_ done: () -> Bool, within limit: Duration = .seconds(10),
               sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now + limit
        let timeout = Task { [weak self] in
            try await Task.sleep(until: deadline)
            self?.send()
        }
        defer { timeout.cancel() }
        while !done(), ContinuousClock.now < deadline {
            await withCheckedContinuation { waiting.append($0) }
        }
        try #require(done(), "not within \(limit)", sourceLocation: sourceLocation)
    }
}

extension ChatListModel {
    /// The list's announcements (rows, places, load state, failures), after the handlers the
    /// screen gave it: the screen has drawn an update when the test wakes.
    func changes() -> Changes {
        let changes = Changes()
        let (update, places, loadState, error) = (onUpdate, onPlaces, onLoadState, onError)
        onUpdate = { update?($0, $1); changes.send() }
        onPlaces = { places?($0); changes.send() }
        onLoadState = { loadState?($0); changes.send() }
        onError = { error?($0); changes.send() }
        return changes
    }
}
