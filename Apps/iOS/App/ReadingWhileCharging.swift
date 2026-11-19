import BackgroundTasks
import LuxCore
import UIKit

/// Search reads what it has left while the iPhone charges: a background processing task, which
/// the system runs when the iPhone is idle and on power, usually at night, with a network (photos
/// and history download). `BackgroundReading` decides what runs; this registers the task and
/// hands it the system's.
@MainActor
final class ReadingWhileCharging {
    static let identifier = "\(AppIdentity.bundleId).reading"

    let reading: BackgroundReading

    /// Registered before launching ends, as the system requires for a scheduled task.
    init(session: Session) {
        reading = BackgroundReading(reader: SessionReader(session: session), requests: Requests())
        // the handler runs on the main queue: it may touch the session.
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.identifier, using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                guard let processing = task as? BGProcessingTask, let self else { return task.setTaskCompleted(success: false) }
                self.reading.start(Time(task: processing))
            }
        }
        if !registered { Log.app.error("background reading: the task is not registered") }
    }

    /// Asks for a task while something is left to read: the app went to the background.
    func schedule() {
        Task { await reading.schedule() }
    }

    /// The system's requests: one at a time (a submit replaces the one before).
    private final class Requests: BackgroundRequests {
        func submit() throws {
            let request = BGProcessingTaskRequest(identifier: ReadingWhileCharging.identifier)
            // reading takes the battery's time, and photos and history come from the server.
            request.requiresExternalPower = true
            request.requiresNetworkConnectivity = true
            try BGTaskScheduler.shared.submit(request)
        }

        func cancel() {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: ReadingWhileCharging.identifier)
        }
    }

    /// The system's task, as the reading uses it.
    private final class Time: BackgroundTime {
        private let task: BGProcessingTask

        init(task: BGProcessingTask) {
            self.task = task
        }

        func onExpiry(_ expire: @escaping @MainActor () -> Void) {
            // the system calls it on a queue of its own.
            task.expirationHandler = { Task { @MainActor in expire() } }
        }

        func complete(success: Bool) {
            task.setTaskCompleted(success: success)
        }
    }
}
