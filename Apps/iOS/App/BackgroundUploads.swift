import BackgroundTasks
import LuxCore
import UIKit

/// Keeps photos and files going out when the user leaves the app: an upload the user started
/// becomes a continued processing task (iOS 26), which the system lets run in the background and
/// shows as a Live Activity with its progress, where the user can also stop it. Swiping the app
/// away in the switcher ends it, as it ends any task. While it runs the sync stays as the app
/// leaves; as it ends in the background, the sync stops and the stores in the App Group close
/// before the system may suspend the app (0xdead10cc).
@MainActor
final class BackgroundUploads {
    static let identifier = "\(AppIdentity.bundleId).uploads"

    private let session: Session
    /// The uploads of the account signed in now; nil signed out.
    private var uploads: Uploads?
    private var task: BGContinuedProcessingTask?
    private var accountChanges: AnyObject?

    /// The system lets the app run for the uploads: their sync stays as the app leaves.
    var keepsAppRunning: Bool { task != nil }

    /// Registers the task once, for the app's life; the account it follows is the session's of
    /// the moment.
    init(session: Session) {
        self.session = session
        // the handler runs on the main queue: it may touch the uploads.
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.identifier, using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                guard let continued = task as? BGContinuedProcessingTask, let self else { return task.setTaskCompleted(success: false) }
                self.run(continued)
            }
        }
        if !registered { Log.app.error("uploads: the background task is not registered") }
        accountChanges = session.uploadsChanges.observe { [weak self] in self?.follow() }
        follow()
    }

    /// Follows the uploads of the account signed in now (another after signing out and in).
    private func follow() {
        guard uploads !== session.uploads else { return }
        uploads?.onStart = nil
        uploads?.onProgress = nil
        uploads?.onFinish = nil
        uploads = session.uploads
        uploads?.onStart = { [weak self] in self?.submit() }
        uploads?.onProgress = { [weak self] in self?.report() }
        uploads?.onFinish = { [weak self] ok in self?.finish(ok) }
    }

    /// Asked as the user sends: the system queues it if it cannot start it at once.
    private func submit() {
        let request = BGContinuedProcessingTaskRequest(identifier: Self.identifier, title: String(localized: "Sending files"),
                                                       subtitle: String(localized: "Preparing…"))
        request.strategy = .queue
        do { try BGTaskScheduler.shared.submit(request) } catch {
            Log.app.error("uploads: no background task: \(String(describing: error), privacy: .public)")
        }
    }

    private func run(_ task: BGContinuedProcessingTask) {
        // everything may already be through when the system starts it.
        guard let uploads, uploads.isActive else { return task.setTaskCompleted(success: true) }
        self.task = task
        // the user stopped it in the Live Activity, or the system had to: the files stay queued
        // in their chats and go when the app is back.
        task.expirationHandler = { [weak self] in
            Task { @MainActor in self?.finish(false) }
        }
        // the bar is the uploads' bytes.
        task.progress.totalUnitCount = 1
        task.progress.addChild(uploads.progress, withPendingUnitCount: 1)
        report()
    }

    /// The Live Activity's "2 of 3 · 4.1 of 12 MB".
    private func report() {
        guard let task, let uploads else { return }
        let bytes = uploads.progress
        let sent = ByteCountFormatter.string(fromByteCount: bytes.completedUnitCount, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: bytes.totalUnitCount, countStyle: .file)
        task.updateTitle(uploads.files == 1 ? String(localized: "Sending a file") : String(localized: "Sending \(uploads.files) files"),
                         subtitle: String(localized: "\(min(uploads.finished + 1, uploads.files)) of \(uploads.files) · \(sent) of \(total)"))
    }

    /// Tells the system the uploads are over, once; in the background, after the sync has
    /// stopped and the stores have closed, since the app may be suspended as soon as it is told.
    private func finish(_ ok: Bool) {
        guard let task else { return }
        self.task = nil
        let session = self.session
        Task {
            if UIApplication.shared.applicationState != .active { await session.enterBackground()?.value }
            task.setTaskCompleted(success: ok)
        }
    }
}
