import Foundation

/// The app's long work (filling the search index, reading photos and what messages mean, loading
/// the search model) runs only while the app may work: in front, or, on the iPhone, in the time a
/// background processing task gives it (a *window*, `openWindow`). Outside them it is ended before
/// iOS suspends the app: a file held as it is suspended ends the app (0xdead10cc), and a model
/// compiled for the Neural Engine takes minutes the system does not give an app in the background.
///
/// The work runs here, and only here: the calls that do it take a `WorkLease`, which only this
/// coordinator hands out, so work started anywhere else does not compile. Leaving, the app
/// cancels the work and waits for it (under the time iOS gives a background task), unless a
/// window is open; coming back, it tells the work's owners to go on. A window is open only while
/// the app is away: coming to the front hands its work over to the front, as it is, and the
/// window's owner hears of it (`openWindow`'s `handOver`).
@MainActor
public final class LongWork {
    public static let shared = LongWork()

    /// The app is in front. On the Mac, always (an app there is not suspended); on the iPhone
    /// from the scene's first move to the front (`enter`): an app the system launched for a
    /// background task works only in the window that task opens.
    public private(set) var isInFront: Bool
    /// Work may start: the app is in front, or a window is open.
    public var isActive: Bool { isInFront || handOver != nil }
    /// The open window's owner, told when the front takes its work over; nil while none is open.
    private var handOver: (@MainActor () -> Void)?
    private var running: [Int: Task<Void, Never>] = [:]
    private var next = 0
    private let returned = Broadcast()
    private let left = Broadcast()

    /// `inFront`: where the app starts (the iPhone's scene says when it comes to the front).
    init(inFront: Bool = LongWork.startsInFront) {
        isInFront = inFront
    }

    #if os(iOS)
    static let startsInFront = false
    #else
    static let startsInFront = true
    #endif

    /// Runs `work` now, under a lease, if work may start; nil otherwise (its owner goes on when
    /// the app comes back, `onReturn`). Its owner keeps it (`WorkJobs`).
    fileprivate func start<Value: Sendable>(_ name: StaticString, priority: TaskPriority,
                                            _ work: @escaping @Sendable (WorkLease) async -> Value) -> Task<Value, Never>? {
        task(name, priority: priority, work)
    }

    /// Runs `work` under a lease and waits for what it gives (cancelled with the caller, or as the
    /// app leaves); nil when work may not start now and it did not run.
    public func run<Value: Sendable>(_ name: StaticString, priority: TaskPriority = .utility,
                                     _ work: @escaping @Sendable (WorkLease) async -> Value) async -> Value? {
        guard let task = task(name, priority: priority, work) else { return nil }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private func task<Value: Sendable>(_ name: StaticString, priority: TaskPriority,
                                       _ work: @escaping @Sendable (WorkLease) async -> Value) -> Task<Value, Never>? {
        guard isActive else {
            Log.app.notice("long work: \(name, privacy: .public) waits for the app to come back")
            return nil
        }
        let id = next
        next += 1
        let task = Task(priority: priority) { [weak self] in
            let value = await work(WorkLease())
            self?.running[id] = nil
            return value
        }
        running[id] = Self.following(task)
        return task
    }

    /// What follows `task` to its end, a cancel of it cancelling `task` too: what is kept to end
    /// the work cancels the work itself, not only the wait for it.
    fileprivate static func following<Value>(_ task: Task<Value, Never>) -> Task<Void, Never> {
        Task { await withTaskCancellationHandler { _ = await task.value } onCancel: { task.cancel() } }
    }

    /// The app leaves the front: no new work starts, and what runs is cancelled and waited for,
    /// unless a window is open (its task goes on with the work). The caller holds a background
    /// task meanwhile (iOS), so the work ends before suspension.
    public func leave() async {
        isInFront = false
        guard handOver == nil else { return }
        await endWork()
    }

    /// The app is in front: the work's owners go on. The work of an open window goes on as the
    /// front's, and the window closes (its owner is told).
    public func enter() {
        let wasActive = isActive
        isInFront = true
        if let handOver {
            self.handOver = nil
            handOver()
        }
        if !wasActive { returned.send() }
    }

    /// Opens a window for work in the background (a processing task's time): work starts until
    /// `closeWindow`, or until the app comes to the front, which takes the work over and calls
    /// `handOver`. False, and nothing opens, while the app is in front (its work is the front's)
    /// or another window is open.
    public func openWindow(handOver: @escaping @MainActor () -> Void) -> Bool {
        guard !isInFront, self.handOver == nil else { return false }
        self.handOver = handOver
        returned.send()
        return true
    }

    /// Closes the open window: unless the app came to the front, what runs is cancelled and
    /// waited for, and what it held goes (`onLeave`).
    public func closeWindow() async {
        // closing already (the system took the time back): this waits for the same end.
        if let closing { return await closing.value }
        guard handOver != nil else { return }
        handOver = nil
        guard !isInFront else { return }
        let closing = Task { await endWork() }
        self.closing = closing
        await closing.value
        self.closing = nil
    }

    /// The window's work being ended, while it is.
    private var closing: Task<Void, Never>?

    /// The app ends: the window closes, and all work is cancelled and waited for.
    public func end() async {
        handOver = nil
        isInFront = false
        await endWork()
    }

    private func endWork() async {
        let tasks = Array(running.values)
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
        // the app may have come back meanwhile (or a window opened): its work keeps what it holds.
        guard !isActive else { return }
        left.send()
    }

    /// Calls `resume` each time work may start again: the app came back to the front, or a
    /// window opened.
    public func onReturn(_ resume: @escaping @MainActor () -> Void) -> AnyObject {
        returned.observe(resume)
    }

    /// Calls `release` each time the work has ended for want of a front or a window: what the
    /// work held for the next piece (a loaded model) goes until it may start again.
    public func onLeave(_ release: @escaping @MainActor () -> Void) -> AnyObject {
        left.observe(release)
    }
}

/// A model's long work: what it started ends with it (it goes, or it stops), so no work outlives
/// what it was for, and none holds a store as the process ends.
@MainActor
public final class WorkJobs {
    private var running: [Int: Task<Void, Never>] = [:]
    private var next = 0

    public init() {}

    /// Runs `work` as long work, kept here; false when work may not start now.
    @discardableResult
    public func start(_ name: StaticString, priority: TaskPriority = .utility,
                      _ work: @escaping @Sendable (WorkLease) async -> Void) -> Bool {
        launch(name, priority: priority, work) != nil
    }

    /// Runs `work` as long work, kept here, and waits for what it gives (cancelled with the
    /// caller, as the app leaves, or as this ends); nil when work may not start now.
    public func run<Value: Sendable>(_ name: StaticString, priority: TaskPriority = .utility,
                                     _ work: @escaping @Sendable (WorkLease) async -> Value) async -> Value? {
        guard let task = launch(name, priority: priority, work) else { return nil }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private func launch<Value: Sendable>(_ name: StaticString, priority: TaskPriority,
                                         _ work: @escaping @Sendable (WorkLease) async -> Value) -> Task<Value, Never>? {
        let id = next
        next += 1
        guard let task = LongWork.shared.start(name, priority: priority, { [weak self] lease in
            let value = await work(lease)
            await self?.finished(id)
            return value
        }) else { return nil }
        running[id] = LongWork.following(task)
        return task
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

/// Proof that the work holding it runs under `LongWork`: the long calls take one, and only the
/// coordinator makes them.
public struct WorkLease: Sendable {
    fileprivate init() {}
}
