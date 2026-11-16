import BackgroundTasks
import LuxCore
import UIKit

/// Keeps the chat list and the badge fresh for when the user opens the app: an app refresh task
/// that the system runs now and then while the app is in the background (when it judges the
/// user will open it soon). Each run is a short sync, until the server answered, then the sync
/// stops as it does when the app leaves the screen.
@MainActor
final class BackgroundRefresh {
    static let identifier = "\(AppIdentity.bundleId).refresh"
    /// The system gives a refresh about 30 s; the sync stops before it runs out.
    private static let budget: Double = 25
    /// Not sooner than this after leaving the app (the system decides when, often later).
    private static let interval: TimeInterval = 15 * 60

    private let session: Session

    /// Registered before launching ends, as the system requires for a scheduled task.
    init(session: Session) {
        self.session = session
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.identifier, using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                guard let refresh = task as? BGAppRefreshTask, let self else { return task.setTaskCompleted(success: false) }
                self.run(refresh)
            }
        }
        if !registered { Log.app.error("refresh: the background task is not registered") }
    }

    /// Asks for the next refresh: the app went to the background, signed in.
    func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: Self.identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: Self.interval)
        do { try BGTaskScheduler.shared.submit(request) } catch {
            // the simulator, or background refresh turned off for the app: no refresh, no harm.
            Log.app.notice("refresh: not scheduled: \(String(describing: error), privacy: .public)")
        }
    }

    /// The refresh under way, and its work.
    private var running: BGAppRefreshTask?
    private var work: Task<Void, Never>?

    private func run(_ task: BGAppRefreshTask) {
        // one at a time, chained: the next is asked for as this one starts.
        schedule()
        running = task
        let session = self.session
        work = Task { [weak self] in
            let fresh = await session.refreshInBackground(within: Self.budget)
            // the user opened the app meanwhile: the refresh stopped its sync, which runs again.
            if UIApplication.shared.applicationState == .active { session.enterForeground() }
            self?.complete(ok: fresh)
        }
        // out of time: the refresh stops where it is, and so does the sync.
        task.expirationHandler = { [weak self] in
            Task { @MainActor in self?.expire() }
        }
    }

    private func expire() {
        work?.cancel()
        let session = self.session
        Task { [weak self] in
            if UIApplication.shared.applicationState != .active { await session.enterBackground() }
            self?.complete(ok: false)
        }
    }

    /// Tells the system the refresh is over, once.
    private func complete(ok: Bool) {
        guard let task = running else { return }
        running = nil
        work = nil
        task.setTaskCompleted(success: ok)
    }
}
