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

    /// Returns once `done` holds, checked at each announcement, or once `limit` passed.
    func until(_ done: () -> Bool, within limit: Duration = .seconds(10),
               sourceLocation: SourceLocation = #_sourceLocation) async {
        let deadline = ContinuousClock.now + limit
        let timeout = Task { [weak self] in
            guard (try? await Task.sleep(until: deadline)) != nil else { return }
            self?.send()
        }
        // half-way, every thread of the process into the log: a machine that is only slow and
        // threads that hold the others up look the same to this wait otherwise.
        let stall = StallReport(after: limit / 2, at: sourceLocation)
        defer { timeout.cancel(); stall.cancel() }
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
    /// The chat's announcements (messages, the composer's mode, the room shown, failures, live or
    /// a jump's rows), after
    /// the handlers it has.
    func changes() -> Changes {
        let changes = Changes()
        let (update, mode, shownRoom, error) = (onUpdate, onMode, onShownRoom, onError)
        onUpdate = { update?($0); changes.send() }
        onMode = { mode?($0); changes.send() }
        onShownRoom = { shownRoom?($0); changes.send() }
        onError = { error?($0); changes.send() }
        let live = onLive
        onLive = { live?($0); changes.send() }
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

/// Where every thread of the test process is, sampled into the log once `after` passed, unless
/// cancelled first. It runs on a thread of its own, not Swift's cooperative pool, so it reports
/// even when that pool's threads are all held. Not the main actor's: a closure made in its
/// isolation is its too, and traps when the global queue runs it.
private final class StallReport {
    private let report: DispatchWorkItem

    init(after: Duration, at location: SourceLocation) {
        report = DispatchWorkItem {
            let sample = Process()
            sample.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
            sample.arguments = [String(ProcessInfo.processInfo.processIdentifier), "2", "-file", "/dev/stdout"]
            print("a wait at \(location) still waits: the process's threads, sampled")
            do {
                try sample.run()
                sample.waitUntilExit()
            } catch {
                print("no sample: \(error)")
            }
        }
        let seconds = Double(after.components.seconds) + Double(after.components.attoseconds) / 1e18
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds, execute: report)
    }

    func cancel() { report.cancel() }
}
