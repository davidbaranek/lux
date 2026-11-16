import BackgroundTasks
import LuxCore
import UIKit

/// Reads every photo now, when the user asks in Settings: a continued processing task (iOS 26),
/// which the system shows as a Live Activity with its progress, keeps going when the user leaves
/// the app, and lets them stop. A stop keeps what was read: the rest is read the next time the
/// app opens, or while it charges (`PhotoReading`).
@MainActor
final class PhotoReadingNow {
    static let identifier = "\(AppIdentity.bundleId).photos-now"

    private let session: Session
    private var task: BGContinuedProcessingTask?
    private var following: AnyObject?
    private var searchOpened: AnyObject?
    /// The account's photo search, once its index is open.
    private var photos: PhotoSearch? { session.search?.photos }

    /// Registered once, at launch; photo search hands it the reading when the user asks.
    init(session: Session) {
        self.session = session
        // the handler runs on the main queue: it may touch photo search.
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.identifier, using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                guard let continued = task as? BGContinuedProcessingTask, let self else { return task.setTaskCompleted(success: false) }
                self.run(continued)
            }
        }
        if !registered { Log.app.error("photo search: the reading task is not registered") }
        // the search opens a moment after the account, and again after signing in.
        searchOpened = session.searchChanges.observe { [weak self] in self?.adopt() }
        adopt()
    }

    private func adopt() {
        photos?.onReadNow = { [weak self] in self?.submit() }
    }

    /// The system starts it at once, or says why not; then the photos are read in the app.
    private func submit() {
        let request = BGContinuedProcessingTaskRequest(identifier: Self.identifier, title: String(localized: "Reading photos"),
                                                       subtitle: String(localized: "Preparing…"))
        request.strategy = .fail
        do { try BGTaskScheduler.shared.submit(request) } catch {
            Log.app.notice("photo search: no continued task, reading in the app: \(String(describing: error), privacy: .public)")
            Task { _ = await photos?.readAll() }
        }
    }

    private func run(_ task: BGContinuedProcessingTask) {
        guard let photos else { return task.setTaskCompleted(success: false) }
        self.task = task
        // the user stopped it in the Live Activity, or the system had to.
        task.expirationHandler = { [weak self] in
            Task { @MainActor in await self?.photos?.stop() }
        }
        following = photos.changes.observe { [weak self] in self?.report() }
        report()
        Task {
            let done = await photos.readAll()
            finish(done)
        }
    }

    /// The Live Activity's bar and "120 of 224 photos".
    private func report() {
        guard let task, let progress = photos?.progress else { return }
        task.progress.totalUnitCount = Int64(max(progress.total, 1))
        task.progress.completedUnitCount = Int64(progress.read)
        task.updateTitle(String(localized: "Reading photos"),
                         subtitle: String(localized: "\(progress.read.formatted(.number)) of \(progress.total.formatted(.number)) photos"))
    }

    private func finish(_ done: Bool) {
        following = nil
        if done { task?.progress.completedUnitCount = task?.progress.totalUnitCount ?? 0 }
        task?.setTaskCompleted(success: done)
        task = nil
    }
}
