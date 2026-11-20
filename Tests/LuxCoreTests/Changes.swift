import Foundation
import Testing
@testable import LuxCore

/// What a model announced, for a test to await: each announcement wakes the waiting test, which
/// checks its condition again. Nothing polls.
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

extension AsyncSequence where Self: Sendable, Element: Sendable {
    /// The first element that `matches`, awaited no longer than `limit`. If none came by then, or
    /// the sequence ended first, the test stops here, as at a failed `#require`.
    func first(where matches: @escaping @Sendable (Element) -> Bool = { _ in true },
               within limit: Duration = .seconds(10),
               sourceLocation: SourceLocation = #_sourceLocation) async throws -> Element {
        let found = try await withThrowingTaskGroup(of: Element?.self) { group in
            group.addTask {
                for try await element in self where matches(element) { return element }
                return nil
            }
            group.addTask {
                try await Task.sleep(for: limit)
                return nil
            }
            // the first to end decides, and the other is cancelled.
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
        return try #require(found, "nothing came within \(limit)", sourceLocation: sourceLocation)
    }
}

extension ChatListModel {
    /// The list's announcements (rows, places, load state, failures), after the handlers it has.
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

extension ThreadModel {
    /// The chat's announcements (messages, the composer's mode, the room shown, failures, live or
    /// a jump's rows), after
    /// the handlers it has.
    func changes() -> Changes {
        let changes = Changes()
        let (update, mode, shownRoom, error) = (onUpdate, onMode, onShownRoom, onError)
        onUpdate = { update?($0, $1); changes.send() }
        onMode = { mode?($0); changes.send() }
        onShownRoom = { shownRoom?($0); changes.send() }
        onError = { error?($0); changes.send() }
        let live = onLive
        onLive = { live?($0); changes.send() }
        let pinned = onPinned
        onPinned = { pinned?($0); changes.send() }
        let pending = onPendingFiles
        onPendingFiles = { pending?($0); changes.send() }
        return changes
    }
}

extension MessageSearch {
    /// The index's announcements: how far it is.
    func changes() -> (Changes, AnyObject) {
        let changes = Changes()
        return (changes, progressChanges.observe { changes.send() })
    }
}

extension SecurityModel {
    /// The model's announcements (what the device needs, the devices).
    func announcements() -> (Changes, AnyObject) {
        let changes = Changes()
        return (changes, self.changes.observe { changes.send() })
    }
}

extension VerificationModel {
    /// The verification's steps and failures, after the handlers it has.
    func changes() -> Changes {
        let changes = Changes()
        let (step, error) = (onStep, onError)
        onStep = { step?($0); changes.send() }
        onError = { error?($0); changes.send() }
        return changes
    }

    /// Whether it is comparing emojis.
    var isComparing: Bool {
        if case .compare = step { true } else { false }
    }
}
