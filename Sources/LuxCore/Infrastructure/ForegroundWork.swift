import Foundation

/// The app's long work (filling the search index, reading photos and what messages mean, loading
/// the search model) runs only while the app is in front, and is ended before iOS suspends it: a
/// file held as it is suspended ends the app (0xdead10cc), and a model compiled for the Neural
/// Engine takes minutes the system does not give an app in the background.
///
/// The work runs here, and only here: the calls that do it take a `ForegroundLease`, which only
/// this coordinator hands out, so work started anywhere else does not compile. Leaving, the app
/// cancels the work and waits for it (under the time iOS gives a background task); coming back,
/// it tells the work's owners to go on.
@MainActor
public final class ForegroundWork {
    public static let shared = ForegroundWork()

    /// The app is in front: work starts. On the Mac, always (an app there is not suspended).
    public private(set) var isActive = true
    private var running: [Int: Task<Void, Never>] = [:]
    private var next = 0
    private let returned = Broadcast()

    private init() {}

    /// Runs `work` now, under a lease, if the app is in front; nil otherwise (its owner goes on
    /// when the app comes back, `onReturn`). Its owner keeps it (`ForegroundJobs`).
    fileprivate func start(_ name: StaticString, priority: TaskPriority,
                           _ work: @escaping @Sendable (ForegroundLease) async -> Void) -> Task<Void, Never>? {
        task(name, priority: priority, work)
    }

    /// Runs `work` under a lease and waits for what it gives (cancelled with the caller, or as the
    /// app leaves); nil when the app is not in front and it did not run.
    public func run<Value: Sendable>(_ name: StaticString, priority: TaskPriority = .utility,
                                     _ work: @escaping @Sendable (ForegroundLease) async -> Value) async -> Value? {
        guard let task = task(name, priority: priority, work) else { return nil }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private func task<Value: Sendable>(_ name: StaticString, priority: TaskPriority,
                                       _ work: @escaping @Sendable (ForegroundLease) async -> Value) -> Task<Value, Never>? {
        guard isActive else {
            Log.app.notice("foreground work: \(name, privacy: .public) waits for the app to come back")
            return nil
        }
        let id = next
        next += 1
        let task = Task(priority: priority) { [weak self] in
            let value = await work(ForegroundLease())
            self?.running[id] = nil
            return value
        }
        running[id] = Task { _ = await task.value }
        return task
    }

    /// The app leaves the front: no new work starts, and what runs is cancelled and waited for.
    /// The caller holds a background task meanwhile (iOS), so the work ends before suspension.
    public func leave() async {
        isActive = false
        let tasks = Array(running.values)
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
    }

    /// The app is in front again: the work's owners go on.
    public func enter() {
        guard !isActive else { return }
        isActive = true
        returned.send()
    }

    /// Calls `resume` each time the app comes back to the front.
    public func onReturn(_ resume: @escaping @MainActor () -> Void) -> AnyObject {
        returned.observe(resume)
    }
}

/// A model's foreground work: what it started ends with it (it goes, or it stops), so no work
/// outlives what it was for, and none holds a store as the process ends.
@MainActor
public final class ForegroundJobs {
    private var running: [Int: Task<Void, Never>] = [:]
    private var next = 0

    public init() {}

    /// Runs `work` as foreground work, kept here; false when the app is not in front.
    @discardableResult
    public func start(_ name: StaticString, priority: TaskPriority = .utility,
                      _ work: @escaping @Sendable (ForegroundLease) async -> Void) -> Bool {
        let id = next
        next += 1
        guard let task = ForegroundWork.shared.start(name, priority: priority, { [weak self] lease in
            await work(lease)
            await self?.finished(id)
        }) else { return false }
        running[id] = task
        return true
    }

    private func finished(_ id: Int) {
        running[id] = nil
    }

    /// Ends the work: cancelled, and waited for.
    public func end() async {
        let tasks = Array(running.values)
        running = [:]
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
    }

    isolated deinit {
        for task in running.values { task.cancel() }
    }
}

/// Proof that the work holding it runs under `ForegroundWork`: the long calls take one, and only
/// the coordinator makes them.
public struct ForegroundLease: Sendable {
    fileprivate init() {}
}
