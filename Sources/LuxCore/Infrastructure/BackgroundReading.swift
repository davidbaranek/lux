import Foundation

/// Reads what search has left (the index's history, photos, what messages mean) in the time the
/// system gives the iPhone app while it charges: a background processing task, which the system
/// runs when the device is idle, usually at night, and ends when it wants the time back. The
/// same owners do the same work as in front (`MessageSearch.readWhatIsLeft`), in a window of
/// `LongWork`, so front and background never read at once:
///
/// - a task the system starts while the app is in front does nothing: the front reads;
/// - the app coming to the front during a task takes its work over as it is (the window closes
///   without stopping it), and the task ends;
/// - the system taking the time back, Low Power or Low Data Mode, or a device grown hot, stops
///   the work, waits for it to end and closes what the task opened, then ends the task;
/// - the task ends once, after its work, and asks for another only while something is left.
@MainActor
public final class BackgroundReading {
    private let work: LongWork
    private let reader: any BackgroundReader
    private let requests: any BackgroundRequests
    private let conditions: any WorkConditions
    /// The task under way, if any.
    private var current: Run?

    /// One task's run: its time, and whether it was stopped or ended.
    private final class Run {
        let time: any BackgroundTime
        var isStopped = false
        var isCompleted = false
        var watching: AnyObject?

        init(time: any BackgroundTime) {
            self.time = time
        }
    }

    public init(work: LongWork = .shared, reader: any BackgroundReader, requests: any BackgroundRequests,
                conditions: any WorkConditions = DeviceConditions()) {
        self.work = work
        self.reader = reader
        self.requests = requests
        self.conditions = conditions
    }

    /// Asks for a task while something is left to read (the app leaves the front, a task ends);
    /// with nothing left, the request there may be goes. The system keeps one request: this one
    /// replaces it.
    public func schedule() async {
        guard await reader.hasWorkLeft() else {
            requests.cancel()
            return
        }
        do { try requests.submit() } catch {
            // the simulator, or Background App Refresh turned off for the app: the front reads.
            Log.app.notice("background reading: not scheduled: \(String(describing: error), privacy: .public)")
        }
    }

    /// The system started a task: it reads what is left, unless the front does or the device
    /// should not work now.
    public func start(_ time: any BackgroundTime) {
        if work.isInFront {
            // the front reads; the next leaving asks for a task again.
            return time.complete(success: true)
        }
        guard current == nil else { return time.complete(success: false) }
        if let reason = conditions.reason {
            Log.app.notice("background reading: not now, \(reason, privacy: .public)")
            time.complete(success: false)
            Task { await schedule() }
            return
        }
        let run = Run(time: time)
        current = run
        time.onExpiry { [weak self] in self?.stop(run, because: "the system took the time back") }
        run.watching = conditions.observe { [weak self] in
            guard let self, let reason = conditions.reason else { return }
            stop(run, because: reason)
        }
        Task { await read(run) }
    }

    private func read(_ run: Run) async {
        var done = false
        if await reader.begin(), !run.isStopped,
           work.openWindow(handOver: { [weak self] in self?.handOver(run) }) {
            done = await reader.read()
        }
        // the work has ended (or was handed to the front) before anything closes under it.
        await work.closeWindow()
        await reader.end()
        run.watching = nil
        if current === run { current = nil }
        await schedule()
        complete(run, success: done && !run.isStopped)
    }

    /// The work stops where it is (what was read stays): the window closes, which cancels the
    /// work and waits for it; the run then closes what it opened and ends the task.
    private func stop(_ run: Run, because reason: String) {
        guard !run.isStopped, !run.isCompleted else { return }
        run.isStopped = true
        Log.app.notice("background reading: stops, \(reason, privacy: .public)")
        Task { await work.closeWindow() }
    }

    /// The app came to the front: its reading goes on as the front's, and the task ends now.
    private func handOver(_ run: Run) {
        Log.app.notice("background reading: the app came to the front and reads on")
        complete(run, success: true)
    }

    /// Tells the system the task is over, once.
    private func complete(_ run: Run, success: Bool) {
        guard !run.isCompleted else { return }
        run.isCompleted = true
        run.time.complete(success: success)
    }
}

/// A background processing task's time, as `BackgroundReading` uses it.
@MainActor
public protocol BackgroundTime: AnyObject {
    /// Calls `expire` when the system takes the time back.
    func onExpiry(_ expire: @escaping @MainActor () -> Void)
    /// Tells the system the task is over (once).
    func complete(success: Bool)
}

/// The system's requests for a background processing task.
@MainActor
public protocol BackgroundRequests: AnyObject {
    /// Asks for a task, in place of the one asked for before.
    func submit() throws
    /// Takes back the task asked for, if any.
    func cancel()
}

/// What the background reading reads: the account's search, as `Session` opens it.
@MainActor
public protocol BackgroundReader: AnyObject {
    /// Opens what reading needs; false when there is nothing to read for now.
    func begin() async -> Bool
    /// Reads what is left, as long work; true when nothing is left.
    func read() async -> Bool
    /// Closes what `begin` opened, unless the app came to the front.
    func end() async
    /// Something is left to read.
    func hasWorkLeft() async -> Bool
}

/// Whether heavy work should wait now, and when that may have changed.
@MainActor
public protocol WorkConditions: AnyObject {
    /// Why the work waits; nil when it need not.
    var reason: String? { get }
    /// Calls `changed` each time the conditions may have changed.
    func observe(_ changed: @escaping @MainActor () -> Void) -> AnyObject
}

/// The device's: Low Power or Low Data Mode (`Saving`), and its heat. At a serious thermal state
/// Apple asks apps to stop or defer work that heats the device (`ProcessInfo.ThermalState`).
@MainActor
public final class DeviceConditions: WorkConditions {
    public init() {}

    public var reason: String? {
        switch Saving.shared.reason {
        case .battery?: return "Low Power Mode"
        case .data?: return "Low Data Mode"
        case nil: break
        }
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical: return "the device is hot"
        default: return nil
        }
    }

    public func observe(_ changed: @escaping @MainActor () -> Void) -> AnyObject {
        Watch(saving: Saving.shared.changes.observe(changed),
              heat: NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil,
                                                           queue: .main) { _ in MainActor.assumeIsolated { changed() } })
    }

    /// Both watches; letting go of it ends them.
    private final class Watch {
        let saving: AnyObject
        let heat: any NSObjectProtocol

        init(saving: AnyObject, heat: any NSObjectProtocol) {
            self.saving = saving
            self.heat = heat
        }

        deinit { NotificationCenter.default.removeObserver(heat) }
    }
}

/// The session's search, read in the background.
@MainActor
public final class SessionReader: BackgroundReader {
    private let session: Session
    /// The search `begin` opened.
    private var search: MessageSearch?

    public init(session: Session) {
        self.session = session
    }

    public func begin() async -> Bool {
        search = await session.beginBackgroundWork()
        return search != nil
    }

    public func read() async -> Bool {
        await search?.readWhatIsLeft() ?? false
    }

    public func end() async {
        search = nil
        await session.endBackgroundWork()
    }

    public func hasWorkLeft() async -> Bool {
        await session.search?.hasWorkLeft() ?? false
    }
}
