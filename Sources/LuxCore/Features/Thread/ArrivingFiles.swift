import Foundation

/// The files put in the composer before they are on disk: a photo or a video the library is still
/// writing, from iCloud if it is only there. Each shows at once with how far it has come, and its
/// video choice follows once it is there. Sending one still on its way waits for it (`take`), and
/// taking it out stops it.
@MainActor
public final class ArrivingFiles {
    /// How far each file has come, 0 to 1, by its place in the composer.
    public private(set) var progress: [URL: Double] = [:] {
        didSet { if progress != oldValue { onChange?() } }
    }
    public var onChange: (() -> Void)?
    /// A file is there (true), or could not come (false; the log says why).
    var onArrived: ((URL, Bool) -> Void)?
    private var arrivals: [URL: Task<Void, any Error>] = [:]
    private let tasks = TaskBag()

    init() {}

    isolated deinit {
        for arrival in arrivals.values { arrival.cancel() }
    }

    func contains(_ file: URL) -> Bool { arrivals[file] != nil }

    /// `file` comes as `write` writes it, telling how far it has come.
    func expect(_ file: URL, write: @escaping @MainActor (_ progress: @escaping @Sendable (Double) -> Void) async throws -> Void) {
        progress[file] = 0
        let arrival = Task { [weak self] in
            try await write { share in Task { @MainActor in self?.advance(file, to: share) } }
        }
        arrivals[file] = arrival
        tasks.run { [weak self] in
            let arrived = await bestEffort("arriving file") { try await arrival.value } != nil
            guard let self, arrivals[file] == arrival else { return }
            arrivals[file] = nil
            progress[file] = nil
            onArrived?(file, arrived)
        }
    }

    /// Taken out of the composer: it stops coming.
    func remove(_ file: URL) {
        arrivals.removeValue(forKey: file)?.cancel()
        progress[file] = nil
    }

    /// The files are sent: those still on their way are the upload's from now on.
    func take(_ files: [URL]) -> [URL: Task<Void, any Error>] {
        var taken: [URL: Task<Void, any Error>] = [:]
        for file in files {
            if let arrival = arrivals.removeValue(forKey: file) { taken[file] = arrival }
            progress[file] = nil
        }
        return taken
    }

    private func advance(_ file: URL, to share: Double) {
        guard progress[file] != nil else { return }
        progress[file] = min(max(share, 0), 1)
    }
}
