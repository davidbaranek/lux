import Foundation
import Synchronization

/// A clock that moves only when the test moves it (`advance`): work that waits on it waits until
/// then, and no test waits for real time. Each wait that begins is told on `sleeps`.
final class TestClock: Clock, Sendable {
    struct Instant: InstantProtocol {
        fileprivate var offset: Duration

        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now = Instant(offset: .zero)
        var sleepers: [UUID: Sleeper] = [:]
        /// Sleeps cancelled before they began to wait.
        var cancelled: Set<UUID> = []
    }

    private let state = Mutex(State())
    /// Each wait, as it begins: its deadline.
    let sleeps: AsyncStream<Instant>
    private let sleeping: AsyncStream<Instant>.Continuation

    init() {
        (sleeps, sleeping) = AsyncStream.makeStream()
    }

    var now: Instant { state.withLock { $0.now } }
    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let early: (any Error)?? = state.withLock { state in
                    if state.cancelled.remove(id) != nil { return .some(CancellationError()) }
                    if deadline <= state.now { return .some(nil) }
                    state.sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    return .none
                }
                switch early {
                case .some(.some(let error)): continuation.resume(throwing: error)
                case .some(.none): continuation.resume()
                case .none: sleeping.yield(deadline)
                }
            }
        } onCancel: {
            let sleeper = state.withLock { state in
                guard let sleeper = state.sleepers.removeValue(forKey: id) else {
                    state.cancelled.insert(id)
                    return Sleeper?.none
                }
                return sleeper
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves the clock on by `duration`: the waits it passes end.
    func advance(by duration: Duration) {
        let woken = state.withLock { state in
            state.now = state.now.advanced(by: duration)
            let now = state.now
            let due = state.sleepers.filter { $0.value.deadline <= now }
            for id in due.keys { state.sleepers[id] = nil }
            return due.values.map(\.continuation)
        }
        for continuation in woken { continuation.resume() }
    }
}
