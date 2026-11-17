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

    /// How much longer a wait may take: `LUX_TEST_TIME_SCALE` (CI sets it under Thread Sanitizer,
    /// which runs the code several times slower on a small virtual machine). The limit guards against
    /// a hang, not a slow machine.
    nonisolated static let timeScale: Int = ProcessInfo.processInfo.environment["LUX_TEST_TIME_SCALE"].flatMap { Int($0) } ?? 1

    /// Returns once `done` holds, checked at each announcement, or once `limit` (times
    /// `timeScale`) passed.
    func until(_ done: () -> Bool, within limit: Duration = .seconds(10),
               sourceLocation: SourceLocation = #_sourceLocation) async {
        let deadline = ContinuousClock.now + limit * Self.timeScale
        let timeout = Task { [weak self] in
            guard (try? await Task.sleep(until: deadline)) != nil else { return }
            self?.send()
        }
        defer { timeout.cancel() }
        while !done(), ContinuousClock.now < deadline {
            await withCheckedContinuation { waiting.append($0) }
        }
        #expect(done(), sourceLocation: sourceLocation)
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
    /// The chat's announcements (messages, the composer's mode, the room shown, failures), after
    /// the handlers it has.
    func changes() -> Changes {
        let changes = Changes()
        let (update, mode, shownRoom, error) = (onUpdate, onMode, onShownRoom, onError)
        onUpdate = { update?($0); changes.send() }
        onMode = { mode?($0); changes.send() }
        onShownRoom = { shownRoom?($0); changes.send() }
        onError = { error?($0); changes.send() }
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
