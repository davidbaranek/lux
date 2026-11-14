import BackgroundTasks
import LuxCore
import UIKit

/// Keeps photos and files going out when the user leaves the app: an upload the user started
/// becomes a continued processing task (iOS 26), which the system lets run in the background and
/// shows as a Live Activity with its progress, where the user can also stop it. Swiping the app
/// away in the switcher ends it, as it ends any task.
@MainActor
final class BackgroundUploads {
    static let identifier = "\(AppIdentity.bundleId).uploads"

    private let uploads: Uploads
    private var task: BGContinuedProcessingTask?

    init(uploads: Uploads) {
        self.uploads = uploads
        // the handler runs on the main queue: it may touch the uploads.
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.identifier, using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                guard let continued = task as? BGContinuedProcessingTask, let self else { return task.setTaskCompleted(success: false) }
                self.run(continued)
            }
        }
        if !registered { Log.app.error("uploads: the background task is not registered") }
        uploads.onStart = { [weak self] in self?.submit() }
        uploads.onProgress = { [weak self] in self?.report() }
        uploads.onFinish = { [weak self] ok in self?.finish(ok) }
        uploads.onError = { error in Log.app.error("upload: \(String(describing: error), privacy: .public)") }
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
        guard uploads.isActive else { return task.setTaskCompleted(success: true) }
        self.task = task
        // the user stopped it in the Live Activity, or the system had to: the files stay queued
        // in their chats and go when the app is back.
        task.expirationHandler = { [weak self] in
            Task { @MainActor in self?.task = nil }
        }
        task.progress.totalUnitCount = 1000
        report()
    }

    /// The Live Activity's bar and "2 of 3 · 4.1 of 12 MB".
    private func report() {
        guard let task else { return }
        let bytes = uploads.progress
        task.progress.completedUnitCount = Int64(bytes.fractionCompleted * 1000)
        let sent = ByteCountFormatter.string(fromByteCount: bytes.completedUnitCount, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: bytes.totalUnitCount, countStyle: .file)
        task.updateTitle(uploads.files == 1 ? String(localized: "Sending a file") : String(localized: "Sending \(uploads.files) files"),
                         subtitle: String(localized: "\(min(uploads.finished + 1, uploads.files)) of \(uploads.files) · \(sent) of \(total)"))
    }

    private func finish(_ ok: Bool) {
        task?.progress.completedUnitCount = task?.progress.totalUnitCount ?? 0
        task?.setTaskCompleted(success: ok)
        task = nil
    }
}
