import Foundation
import Testing
@testable import LuxCore

/// The files waiting in the composer: one changed before it goes (marked up) keeps its place.
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
}
