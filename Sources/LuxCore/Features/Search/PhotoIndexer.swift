import Foundation

/// Reads the photos the search index keeps, the newest first, once photo search is on: each
/// photo downloads (decrypted) into a folder of its own, its words and look are read on the
/// device, and the file goes. One photo at a time, off the main thread.
actor PhotoIndexer {
    /// How far the reading is, for Settings.
    struct Progress: Sendable, Equatable {
        var read: Int
        var total: Int
        var isReading: Bool
    }

    /// Kept together: few writes, and little lost when the system ends the work.
    private static let batch = 8

    private let store: LocalStore
    private let account: Task<RustAccount, any Error>
    private let directory: URL
    private let report: @Sendable (Progress) -> Void
    private var reader: PhotoReader
    private var running: Task<Bool, Never>?

    init(store: LocalStore, account: Task<RustAccount, any Error>, directory: URL, model: PhotoSearchModel?,
         report: @escaping @Sendable (Progress) -> Void) {
        self.store = store
        self.account = account
        self.directory = directory
        reader = PhotoReader(model: model)
        self.report = report
    }

    /// The model arrived (the photos are read again with it), or went (photo search is off).
    func use(_ model: PhotoSearchModel?) {
        reader = PhotoReader(model: model)
    }

    /// Reads the photos not read yet, the newest first: at most `limit` (nil: all of them).
    /// True when none is left. A run under way goes on; this one waits for it.
    @discardableResult
    func read(limit: Int?) async -> Bool {
        if let running { return await running.value }
        let run = Task { await readUnread(limit: limit) }
        running = run
        let done = await run.value
        running = nil
        return done
    }

    /// Stops the reading where it is (what was read is kept).
    func stop() {
        running?.cancel()
    }

    /// How many photos the index has, and how many the current reader read.
    func progress() async -> Progress {
        let counts = (try? await store.imageCounts(reader: reader.name)) ?? (total: 0, read: 0)
        return Progress(read: counts.read, total: counts.total, isReading: running != nil)
    }

    private func readUnread(limit: Int?) async -> Bool {
        guard let account = try? await account.value else { return false }
        let reader = self.reader
        var left = limit ?? .max
        defer { Task { await reader.model?.releaseImageEncoder() } }
        while left > 0, !Task.isCancelled {
            guard let photos = try? await store.imagesToRead(by: reader.name, limit: min(left, Self.batch)) else { return false }
            if photos.isEmpty { return true }
            var reads: [PhotoRead] = []
            for photo in photos where !Task.isCancelled {
                if let read = await self.read(photo, by: reader, from: account) {
                    reads.append(read)
                } else {
                    try? await store.imageUnread(photo.eventId)
                }
            }
            do { try await store.setImagesRead(reads) } catch {
                Log.app.error("photo search: \(String(describing: error), privacy: .public)")
                return false
            }
            left -= photos.count
            report(await progress())
        }
        return false
    }

    /// One photo read: downloaded into its own folder, read, and deleted. Nil when it cannot be
    /// had or read.
    private func read(_ photo: (eventId: String, roomId: String), by reader: PhotoReader,
                      from account: RustAccount) async -> PhotoRead? {
        let folder = directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            guard let file = try await account.foundPhotoFile(roomId: photo.roomId, eventId: photo.eventId, directory: folder) else {
                // no photo any more (deleted, replaced): nothing to find in it.
                return PhotoRead(eventId: photo.eventId, reader: reader.name, words: "", embedding: nil)
            }
            let (words, embedding) = try await reader.read(file)
            return PhotoRead(eventId: photo.eventId, reader: reader.name, words: words, embedding: embedding)
        } catch {
            Log.app.notice("photo search: a photo not read: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
