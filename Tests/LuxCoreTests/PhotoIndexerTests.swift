import Foundation
import Synchronization
import Testing
@testable import LuxCore

/// Photo reading without Vision: which photos are due, the newest first, what is kept of them,
/// the tries of a photo that cannot be read, and a new reader reading them again. The reader is
/// made up (each photo's "picture" is a text file of its words), so this runs on any machine;
/// Vision's own reading is `PhotoReaderTests`, by hand where it reads text.
@Suite(.ownFolder, .timeLimit(.minutes(1)))
struct PhotoIndexerReadingTests {
    /// A chat's photos to download: each one's file holds its words. Those in `offline` cannot be
    /// had now (the photo not at fault), until `goOnline`.
    private final class Photos: MediaSourcePort {
        private let offline: Mutex<Set<String>>

        init(offline: Set<String> = []) { self.offline = Mutex(offline) }

        func goOnline() { offline.withLock { $0 = [] } }

        func sharedFile(roomId: String, eventId: String, directory: URL) async throws -> URL {
            if offline.withLock({ $0.contains(eventId) }) { throw AccountFailure.offline }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appending(path: "photo")
            try Data(Self.words(of: eventId).utf8).write(to: file)
            return file
        }

        /// What the photo `eventId` shows.
        static func words(of eventId: String) -> String { "words of \(eventId)" }
    }

    /// Reads a photo's words from its file, and as its look a vector of its words' length; a photo
    /// in `unreadable` is no picture.
    private final class Reader: PhotoReading {
        let name: String
        private let unreadable: Set<String>
        private let state = Mutex<[String]>([])

        init(name: String = "made-up-1", unreadable: Set<String> = []) {
            self.name = name
            self.unreadable = unreadable.map(Photos.words(of:)).reduce(into: []) { $0.insert($1) }
        }

        /// The photos read, by their words, in order.
        var read: [String] { state.withLock { $0 } }

        func read(_ file: URL, lease: ForegroundLease) async throws -> (words: String, embedding: [Float]?) {
            let words = try String(contentsOf: file, encoding: .utf8)
            state.withLock { $0.append(words) }
            if unreadable.contains(words) { throw PhotoSearchError.notAPicture }
            return (words, [Float(words.count), 1])
        }
    }

    /// A store with `count` photos, the newest first: `$photo0` is the newest.
    private func store(photos count: Int) async throws -> LocalStore {
        let store = try await TemporaryFolder.store()
        try await store.addImages((0..<count).map {
            IndexedImage(eventId: "$photo\($0)", roomId: "!room", senderName: "Anna", caption: "",
                         date: Date(timeIntervalSince1970: 1_700_000_000 - Double($0) * 60), isOwn: false)
        })
        return store
    }

    private func downloads() throws -> URL {
        try TemporaryFolder.ofTest.appending(path: "downloads", directoryHint: .isDirectory)
    }

    private func read(_ indexer: PhotoIndexer, limit: Int? = nil) async throws -> Bool {
        try await leased { lease in await indexer.read(limit: limit, lease: lease) }
    }

    @Test func everyPhotoDueIsReadOnceTheNewestFirstAndItsWordsAndLookAreKept() async throws {
        let store = try await store(photos: 3)
        let reader = Reader()
        let indexer = PhotoIndexer(store: store, account: Task { Photos() }, directory: try downloads(), reader: reader) { _ in }

        #expect(try await read(indexer))
        #expect(reader.read == ["$photo0", "$photo1", "$photo2"].map(Photos.words(of:)))
        let counts = try await store.imageCounts(reader: reader.name)
        #expect(counts.total == 3 && counts.read == 3 && counts.withWords == 3 && counts.withEmbedding == 3)
        // found by its words.
        let found = try await store.searchImages("photo1", embedding: nil, minSimilarity: 1)
        #expect(found.map(\.eventId) == ["$photo1"])
        // each download is gone.
        #expect(try FileManager.default.contentsOfDirectory(atPath: try downloads().path).isEmpty)

        // nothing is due: a second reading reads nothing.
        #expect(try await read(indexer))
        #expect(reader.read.count == 3)
    }

    @Test func aLimitedReadingReadsOnlyTheNewestAndSaysMoreAreDue() async throws {
        let store = try await store(photos: 3)
        let reader = Reader()
        let indexer = PhotoIndexer(store: store, account: Task { Photos() }, directory: try downloads(), reader: reader) { _ in }

        #expect(try await read(indexer, limit: 1) == false)
        #expect(reader.read == [Photos.words(of: "$photo0")])
        #expect(try await store.imagesToRead(by: reader.name, limit: 10).map(\.eventId) == ["$photo1", "$photo2"])
    }

    @Test func aPhotoThatIsNoPictureIsTriedThreeTimesThenLeftUntilAnotherReaderComes() async throws {
        let store = try await store(photos: 2)
        let reader = Reader(unreadable: ["$photo1"])
        let indexer = PhotoIndexer(store: store, account: Task { Photos() }, directory: try downloads(), reader: reader) { _ in }

        #expect(try await read(indexer))
        #expect(reader.read.filter { $0 == Photos.words(of: "$photo1") }.count == 3)
        // left: it counts as done, and is not tried again.
        #expect(try await store.imageCounts(reader: reader.name).read == 2)
        #expect(try await read(indexer))
        #expect(reader.read.count == 4)

        // another reader tries it again, and reads every photo.
        let next = Reader(name: "made-up-2")
        await indexer.use(next)
        #expect(try await read(indexer))
        #expect(next.read == ["$photo0", "$photo1"].map(Photos.words(of:)))
        #expect(try await store.imageCounts(reader: next.name).withWords == 2)
    }

    @Test func aPhotoThatCannotBeHadNowWaitsWithItsTriesUntouched() async throws {
        let store = try await store(photos: 2)
        let photos = Photos(offline: ["$photo1"])
        let reader = Reader()
        let indexer = PhotoIndexer(store: store, account: Task { photos }, directory: try downloads(), reader: reader) { _ in }

        // more readings than a photo has tries: each ends at the photo it cannot have.
        for _ in 0..<4 { #expect(try await read(indexer) == false) }
        #expect(reader.read == [Photos.words(of: "$photo0")])
        #expect(try await store.imagesToRead(by: reader.name, limit: 10).map(\.eventId) == ["$photo1"])

        photos.goOnline()
        #expect(try await read(indexer))
        #expect(try await store.imageCounts(reader: reader.name).withWords == 2)
    }
}
