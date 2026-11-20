import Foundation
import Testing
@testable import LuxCore

/// The files waiting in the composer: one changed before it goes (marked up) keeps its place, and
/// one still on its way to the disk (from the library, iCloud) is there at once.
@MainActor
@Suite(.closesDemoSessions, .timeLimit(.minutes(1)))
struct PendingFilesTests {
    private let session: Session

    init() throws {
        session = try DemoSessions.open(rooms: 5, messagesPerRoom: 10)
    }

    @Test func aFileReplacedBeforeItGoesKeepsItsPlaceAmongTheOthers() async throws {
        let row = try #require(try await session.account.value.chats().first)
        let model = ThreadModel(session: session, row: row)
        let changes = model.changes()
        await model.start()
        let folder = try TemporaryFolder.ofTest
        let (first, photo, last, marked) = (folder.appending(path: "first.pdf"), folder.appending(path: "photo.jpg"),
                                            folder.appending(path: "last.txt"), folder.appending(path: "marked/photo.jpg"))
        model.attach([first, photo, last])
        try await changes.until { model.pendingFiles == [first, photo, last] }

        model.replacePending(photo, with: marked)
        try await changes.until { model.pendingFiles == [first, marked, last] }

        // one no longer waiting changes nothing.
        model.replacePending(photo, with: folder.appending(path: "other.jpg"))
        #expect(model.pendingFiles == [first, marked, last])
    }

    @Test func aFileStillComingIsInTheComposerAtOnceAndTakingItOutStopsIt() async throws {
        let row = try #require(try await session.account.value.chats().first)
        let model = ThreadModel(session: session, row: row)
        let changes = model.changes()
        await model.start()
        let folder = try TemporaryFolder.ofTest
        let (coming, stopped) = (folder.appending(path: "coming.mov"), folder.appending(path: "stopped.mov"))
        let halfway = Changes()
        model.arriving.onChange = { halfway.send() }

        // it waits in the composer before it is written, with how far it has come.
        let (release, written) = AsyncStream<Void>.makeStream()
        model.attach(coming) { progress in
            progress(0.5)
            for await _ in release { break }
        }
        try await changes.until { model.pendingFiles == [coming] }
        try await halfway.until { model.arriving.progress[coming] == 0.5 }

        // taken out while it comes: its writing is cancelled.
        let cancelled = Changes()
        let stop = Stopped()
        model.attach(stopped) { _ in
            do { try await Task.sleep(for: .seconds(60)) } catch {
                stop.happened = true
                cancelled.send()
                throw error
            }
        }
        try await changes.until { model.pendingFiles == [coming, stopped] }
        model.removePending(stopped)
        try await cancelled.until { stop.happened }
        try await changes.until { model.pendingFiles == [coming] }

        // there: it no longer shows as coming.
        written.yield()
        try await halfway.until { model.arriving.progress.isEmpty }
        #expect(model.pendingFiles == [coming])
    }

    @Test func aFileThatCannotComeLeavesTheComposer() async throws {
        let row = try #require(try await session.account.value.chats().first)
        let model = ThreadModel(session: session, row: row)
        let changes = model.changes()
        await model.start()
        let file = try TemporaryFolder.ofTest.appending(path: "gone.jpg")
        let (release, fail) = AsyncStream<Void>.makeStream()
        model.attach(file) { _ in
            for await _ in release { break }
            throw CocoaError(.fileReadNoSuchFile)
        }
        try await changes.until { model.pendingFiles == [file] }
        fail.yield()
        try await changes.until { model.pendingFiles.isEmpty }
        #expect(model.arriving.progress.isEmpty)
    }
}

/// Whether a file's writing was stopped.
@MainActor
private final class Stopped {
    var happened = false
}
