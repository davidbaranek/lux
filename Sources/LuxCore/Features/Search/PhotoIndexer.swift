import Foundation

/// Reads the photos the search index keeps, the newest first, once photo search is on: each
/// photo downloads (decrypted) into a folder of its own, its words and look are read on the
/// device, and the file goes. One photo at a time, off the main thread.
public actor PhotoIndexer {
    /// How far the reading is, for Settings and the reading's Live Activity.
    public struct Progress: Sendable, Equatable {
        public var total = 0
        /// Read by the current reader; the others wait for it.
        public var read = 0
        /// Their words read (the basic index).
        public var withWords = 0
        /// With an embedding (search by look).
        public var withEmbedding = 0
        public var isReading = false
    }

    /// Kept together: few writes, and little lost when the system ends the work.
    private static let batch = 8

    private let store: LocalStore
    private let account: Task<any MediaSourcePort, any Error>
    private let directory: URL
    private let report: @Sendable (Progress) -> Void
    private var reader: PhotoReader
    /// The reading under way, if any: one at a time.
    private var running: Run?
    /// How many times the reading was stopped: a reading waiting for another does not start
    /// after a stop.
    private var stops = 0
    /// Readings asked for that wait for a stopped one to end: the user sees them as reading.
    private var waiting = 0

    private struct Run {
        let id: Int
        let task: Task<Bool, Never>
    }
    private var runs = 0

    init(store: LocalStore, account: Task<any MediaSourcePort, any Error>, directory: URL, model: PhotoSearchModel?,
         report: @escaping @Sendable (Progress) -> Void) {
        self.store = store
        self.account = account
        self.directory = directory
        reader = PhotoReader(model: model)
        self.report = report
    }

    /// The model arrived (the photos are read again with it), or went (photo search is off): a
    /// photo the last reader gave up on is tried again by this one.
    func use(_ model: PhotoSearchModel?) async {
        reader = PhotoReader(model: model)
        await bestEffort("photo search: retry unread photos") { try await store.retryUnreadImages() }
    }

    /// Reads the photos not read yet, the newest first: at most `limit` (nil: all of them).
    /// True when none is left. A run under way goes on, and this one after it if it reads more;
    /// a stop ends both. A stopped run still ending (its photo finishing) is waited for, and
    /// this one starts after it.
    @discardableResult
    func read(limit: Int?, lease: ForegroundLease) async -> Bool {
        let asked = stops
        while let current = running {
            let stopped = current.task.isCancelled
            if stopped { waiting += 1; report(await progress()) }
            let done = await current.task.value
            if stopped { waiting -= 1 }
            if running?.id == current.id { running = nil }
            guard stops == asked else { report(await progress()); return false }
            // a run that went on to its end answers for this one too, unless this one reads all.
            if !stopped, limit != nil || done { return done }
        }
        runs += 1
        let run = Run(id: runs, task: Task { await readUnread(limit: limit, lease: lease) })
        running = run
        report(await progress())
        // the caller's cancel (the app leaving the front) ends the reading too.
        let done = await withTaskCancellationHandler { await run.task.value } onCancel: { run.task.cancel() }
        if running?.id == run.id { running = nil }
        report(await progress())
        return done
    }

    /// Stops the reading where it is (what was read is kept), and the readings waiting for it.
    /// It shows as stopped at once, while the photo being read finishes.
    func stop() async {
        stops += 1
        running?.task.cancel()
        report(await progress())
    }

    /// Whether photos are being read, as the user sees it: a stopped run that is still ending is
    /// not, a reading waiting for it is.
    private var isReading: Bool {
        waiting > 0 || running.map { !$0.task.isCancelled } ?? false
    }

    /// How many photos the index has, and how many the current reader read.
    func progress() async -> Progress {
        guard let counts = await bestEffort("photo search: counts", { try await store.imageCounts(reader: reader.name) }) else {
            return Progress(isReading: isReading)
        }
        return Progress(total: counts.total, read: counts.read, withWords: counts.withWords, withEmbedding: counts.withEmbedding,
                        isReading: isReading)
    }

    private func readUnread(limit: Int?, lease: ForegroundLease) async -> Bool {
        guard let account = await bestEffort("photo search: the account", { try await account.value }) else { return false }
        let reader = self.reader
        var left = limit ?? .max
        defer { Task { await reader.model?.releaseImageEncoder() } }
        while left > 0, !Task.isCancelled {
            guard let photos = await bestEffort("photo search: photos to read", { try await store.imagesToRead(by: reader.name, limit: min(left, Self.batch)) })
            else { return false }
            if photos.isEmpty { return true }
            var reads: [PhotoRead] = []
            let started = ContinuousClock.now
            var stopped = false
            for photo in photos where !Task.isCancelled {
                switch await self.read(photo, by: reader, from: account, lease: lease) {
                case .read(let read): reads.append(read)
                case .unreadable: await bestEffort("photo search: count a try") { try await store.imageUnread(photo.eventId) }
                case .notNow: stopped = true
                }
                if stopped { break }
            }
            do { try await store.setImagesRead(reads) } catch {
                Log.app.error("photo search: \(String(describing: error), privacy: .public)")
                return false
            }
            // what failed is not the photos' (stopped, offline, no reading in the background):
            // they wait for the next reading, their tries untouched.
            if stopped || Task.isCancelled { return false }
            left -= photos.count
            let progress = await progress()
            let each = (ContinuousClock.now - started) / photos.count
            Log.metrics.notice("""
                photo search: \(progress.read) of \(progress.total) photos read, \
                \(each.formatted(.units(allowed: [.milliseconds])), privacy: .public) each (download and reading)
                """)
            report(progress)
        }
        return false
    }

    /// How reading one photo went.
    private enum Outcome {
        case read(PhotoRead)
        /// The photo cannot be had (deleted, not allowed) or is no picture: a try is counted,
        /// and after a few it is left.
        case unreadable
        /// The reading cannot go on now (stopped, offline, the system refused the work): the
        /// photo is not at fault.
        case notNow
    }

    /// One photo read: downloaded into its own folder, read, and deleted.
    private func read(_ photo: (eventId: String, roomId: String), by reader: PhotoReader,
                      from account: any MediaSourcePort, lease: ForegroundLease) async -> Outcome {
        let folder = directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { bestEffort("photo search: the photo's folder stays") { try FileManager.default.removeItemIfPresent(at: folder) } }
        do {
            let file = try await account.sharedFile(roomId: photo.roomId, eventId: photo.eventId, directory: folder)
            let (words, embedding) = try await reader.read(file, lease: lease)
            return .read(PhotoRead(eventId: photo.eventId, reader: reader.name, words: words, embedding: embedding))
        } catch {
            let unreadable = !Task.isCancelled && Self.isThePhotos(error)
            Log.app.notice("""
                photo search: a photo not read (\(unreadable ? "unreadable" : "not now", privacy: .public)): \
                \(String(describing: error), privacy: .public)
                """)
            return unreadable ? .unreadable : .notNow
        }
    }

    /// Whether `error` is the photo's own: reading it again would fail the same way.
    private static func isThePhotos(_ error: any Error) -> Bool {
        switch error {
        case PhotoSearchError.notAPicture: true
        case let failure as AccountFailure:
            switch failure {
            case .unknownChat, .unknownMessage, .notAllowed, .forbidden, .serverRefused: true
            default: false
            }
        default: false
        }
    }
}
