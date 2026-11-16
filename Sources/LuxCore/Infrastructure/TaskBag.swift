import Foundation

/// The tasks a screen or a model starts, owned: they end with their owner (cancelled as it goes),
/// or sooner with `cancelAll()` (its view went away). A task that ends leaves the bag.
///
/// A task holds its owner weakly (`[weak self]`), so the owner can go, and its bag cancel the rest.
@MainActor
public final class TaskBag {
    private var tasks: [Int: Task<Void, Never>] = [:]
    private var keys: [String: Int] = [:]
    private var next = 0

    public init() {}

    isolated deinit { cancelAll() }

    /// The tasks running now.
    public var count: Int { tasks.count }

    /// Starts `work`. A cancellation it throws (a cancelled `Task.sleep`, say) only ends it.
    /// `key`: a newer task of the same key cancels the older one (a newer jump, a newer download).
    public func run(_ key: String? = nil, _ work: @escaping @MainActor () async throws -> Void) {
        let id = next
        next += 1
        if let key {
            if let older = keys[key] { tasks.removeValue(forKey: older)?.cancel() }
            keys[key] = id
        }
        tasks[id] = Task { [weak self] in
            do { try await work() } catch is CancellationError {} catch {
                Log.app.error("task: \(String(describing: error), privacy: .public)")
            }
            self?.ended(id, key: key)
        }
    }

    /// Cancels every task running (the view went away).
    public func cancelAll() {
        for task in tasks.values { task.cancel() }
        tasks = [:]
        keys = [:]
    }

    private func ended(_ id: Int, key: String?) {
        tasks[id] = nil
        if let key, keys[key] == id { keys[key] = nil }
    }
}
