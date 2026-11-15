import BackgroundTasks
import LuxCore
import UIKit

/// Reads the photos photo search has not read yet, while the iPhone charges (a background
/// processing task: the system runs it when the iPhone is idle, usually at night, and ends it
/// when it wants the time back). The reading goes on from where it stopped, the next time.
@MainActor
final class PhotoReading {
    static let identifier = "\(AppIdentity.bundleId).photos"

    private let session: Session
    private var running: BGProcessingTask?
    private var work: Task<Void, Never>?

    /// Registered before launching ends, as the system requires for a scheduled task.
    init(session: Session) {
        self.session = session
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.identifier, using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                guard let processing = task as? BGProcessingTask, let self else { return task.setTaskCompleted(success: false) }
                self.run(processing)
            }
        }
        if !registered { Log.app.error("photo search: the background task is not registered") }
    }

    /// Asks for a reading while the iPhone charges: the app went to the background. The system
    /// keeps one request; asking again replaces it.
    func schedule() {
        // nothing to read: no task to wake the iPhone for (new photos ask for one again).
        guard session.search?.photos.hasUnread ?? true else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.identifier)
            return
        }
        let request = BGProcessingTaskRequest(identifier: Self.identifier)
        // the photos download from the server, and reading them takes the battery's time.
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = true
        do { try BGTaskScheduler.shared.submit(request) } catch {
            Log.app.notice("photo search: not scheduled: \(String(describing: error), privacy: .public)")
        }
    }

    private func run(_ task: BGProcessingTask) {
        running = task
        let session = self.session
        work = Task { [weak self] in
            let done = await session.readPhotosInBackground()
            if UIApplication.shared.applicationState != .active { session.enterBackground() }
            // photos left: the next time goes on.
            if !done { self?.schedule() }
            self?.complete(ok: done)
        }
        task.expirationHandler = { [weak self] in
            Task { @MainActor in await self?.expire() }
        }
    }

    private func expire() async {
        await session.stopReadingPhotos()
        work?.cancel()
        if UIApplication.shared.applicationState != .active { session.enterBackground() }
        schedule()
        complete(ok: false)
    }

    private func complete(ok: Bool) {
        guard let task = running else { return }
        running = nil
        work = nil
        task.setTaskCompleted(success: ok)
    }
}
