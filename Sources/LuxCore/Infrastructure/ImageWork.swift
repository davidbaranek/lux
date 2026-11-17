import Dispatch

/// Where the work that holds its thread runs: decoding and drawing pictures (ImageIO, Core
/// Graphics), reading a photo's words (Vision) and the model's embeddings (Core ML). None of it
/// suspends, and each piece takes its thread for long (seconds on a slow device or a simulator
/// without a GPU). Swift's cooperative pool has one thread per core and is everyone's: a few such
/// pieces there leave every other task of the app waiting. Tasks that do this work prefer this
/// executor (`Task(executorPreference:)`), whose threads are its own queue's, and the pool stays
/// free; what they await in between (the store, the core) still runs where it runs.
final class ImageWork: TaskExecutor {
    static let executor = ImageWork()

    private let queue = DispatchQueue(label: "lux.image-work", qos: .utility, attributes: .concurrent)

    private init() {}

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.async { job.runSynchronously(on: self.asUnownedTaskExecutor()) }
    }
}
