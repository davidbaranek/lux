import Foundation
import Testing
@testable import LuxCore

/// The uploads over their port alone: a file goes to its chat's queue, its upload followed as
/// the core streams it; what cannot go reaches the chat that sent it; the account's end ends them.
@MainActor
struct UploadsTests {
    /// The account's send queues: each file sent gets a stream the test drives.
    private actor Server: UploadsPort {
        struct Sent {
            let name: String
            let caption: String?
            let replyTo: String?
            let states: AsyncStream<UploadState>.Continuation
        }

        let limit: Int
        let refusal: (any Error)?
        /// Each file as it is queued, and each upload no longer followed.
        nonisolated let queued: AsyncStream<Sent>
        nonisolated let unfollowed: AsyncStream<Void>
        private let queuing: AsyncStream<Sent>.Continuation
        private let unfollowing: AsyncStream<Void>.Continuation

        init(limit: Int = 1_000_000, refusal: (any Error)? = nil) {
            self.limit = limit
            self.refusal = refusal
            (queued, queuing) = AsyncStream.makeStream()
            (unfollowed, unfollowing) = AsyncStream.makeStream()
        }

        func maxUploadSize() -> Int { limit }

        func send(_ attachment: OutgoingAttachment, roomId: String, threadRoot: String?, caption: String?, replyTo: String?)
            throws -> AsyncStream<UploadState> {
            if let refusal { throw refusal }
            let (states, continuation) = AsyncStream.makeStream(of: UploadState.self)
            continuation.onTermination = { [unfollowing] _ in unfollowing.yield() }
            queuing.yield(Sent(name: attachment.name, caption: caption, replyTo: replyTo, states: continuation))
            return states
        }
    }

    private struct Refused: Error, Equatable {}

    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("uploads-tests-\(UUID().uuidString)")

    /// A text file of `bytes` bytes, picked to send.
    private func file(_ name: String, bytes: Int) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data(repeating: 0x61, count: bytes).write(to: url)
        return url
    }

    /// Uploads over `server`; their finishes, and the failures `report` hands the chat, as they come.
    private func uploads(over server: Server)
        -> (Uploads, finishes: AsyncStream<Bool>, failures: AsyncStream<any Error>, report: @MainActor (any Error) -> Void) {
        let uploads = Uploads(account: Task { server }, directory: folder)
        let (finishes, finishing) = AsyncStream.makeStream(of: Bool.self)
        uploads.onFinish = { finishing.yield($0) }
        let (failures, failing) = AsyncStream.makeStream(of: (any Error).self)
        return (uploads, finishes, failures, { failing.yield($0) })
    }

    @Test func eachFileIsFollowedAsItsUploadStreamsUntilAllAreSent() async throws {
        let server = Server()
        let (uploads, finishes, _, _) = uploads(over: server)
        var starts = 0
        uploads.onStart = { starts += 1 }
        let (progressed, progressing) = AsyncStream.makeStream(of: Void.self)
        uploads.onProgress = { progressing.yield() }

        uploads.send([try file("a.txt", bytes: 100), try file("b.txt", bytes: 300)], to: "!r", caption: "Both", replyTo: "$q",
                     failure: { Issue.record($0) })
        #expect(starts == 1 && uploads.files == 2 && uploads.isActive)
        var queued = server.queued.makeAsyncIterator()
        let first = try #require(await queued.next())
        let second = try #require(await queued.next())
        // the caption and the answer go with the first file alone.
        #expect((first.name, first.caption, first.replyTo) == ("a.txt", "Both", "$q"))
        #expect((second.name, second.caption, second.replyTo) == ("b.txt", nil, nil))

        first.states.yield(.uploading(0.5))
        for await _ in progressed where uploads.progress.completedUnitCount == 50 { break }
        #expect(uploads.progress.totalUnitCount == 400)
        first.states.end(.sent)
        second.states.yield(.uploading(1))
        second.states.end(.sent)

        var finished = finishes.makeAsyncIterator()
        #expect(await finished.next() == true)
        #expect(uploads.finished == 2 && !uploads.isActive)
        #expect(uploads.progress.fractionCompleted == 1)
    }

    @Test func aFileOverTheServersLimitReachesTheChatAndIsNotSent() async throws {
        let server = Server(limit: 10)
        let (uploads, finishes, failures, report) = uploads(over: server)
        uploads.send([try file("large.txt", bytes: 11)], to: "!r", replyTo: nil, failure: report)

        var failed = failures.makeAsyncIterator()
        let failure = try #require(await failed.next())
        #expect(failure.localizedDescription == AttachmentMaker.Failure.tooLarge(name: "large.txt", limit: 10).localizedDescription)
        var finished = finishes.makeAsyncIterator()
        #expect(await finished.next() == false)
        #expect(uploads.finished == 1)
    }

    @Test func aFileTheQueueRefusesReachesTheChat() async throws {
        let (uploads, finishes, failures, report) = uploads(over: Server(refusal: Refused()))
        uploads.send([try file("a.txt", bytes: 5)], to: "!r", replyTo: nil, failure: report)

        var failed = failures.makeAsyncIterator()
        #expect(await failed.next() as? Refused == Refused())
        var finished = finishes.makeAsyncIterator()
        #expect(await finished.next() == false)
    }

    @Test func anUploadThatFailsEndsTheBatchNotAllThrough() async throws {
        let server = Server()
        let (uploads, finishes, _, _) = uploads(over: server)
        uploads.send([try file("a.txt", bytes: 5)], to: "!r", replyTo: nil, failure: { Issue.record($0) })
        var queued = server.queued.makeAsyncIterator()
        let sent = try #require(await queued.next())
        // the chat shows it failed, with its retry: no error besides.
        sent.states.end(.failed)

        var finished = finishes.makeAsyncIterator()
        #expect(await finished.next() == false)
    }

    @Test func aDiscardedFileIsThroughWithoutFailing() async throws {
        let server = Server()
        let (uploads, finishes, _, _) = uploads(over: server)
        uploads.send([try file("a.txt", bytes: 5)], to: "!r", replyTo: nil, failure: { Issue.record($0) })
        var queued = server.queued.makeAsyncIterator()
        try #require(await queued.next()).states.finish()

        var finished = finishes.makeAsyncIterator()
        #expect(await finished.next() == true)
    }

    @Test func closingWithTheAccountStopsFollowingAndEndsTheBatch() async throws {
        let server = Server()
        let (uploads, finishes, _, _) = uploads(over: server)
        uploads.send([try file("a.txt", bytes: 5)], to: "!r", replyTo: nil, failure: { Issue.record($0) })
        var queued = server.queued.makeAsyncIterator()
        _ = try #require(await queued.next())

        uploads.close()
        var finished = finishes.makeAsyncIterator()
        #expect(await finished.next() == false)
        #expect(!uploads.isActive)
        var unfollowed = server.unfollowed.makeAsyncIterator()
        #expect(await unfollowed.next() != nil)
    }

    @Test func sendingAfterAllWentStartsAFreshBatch() async throws {
        let server = Server()
        let (uploads, finishes, _, _) = uploads(over: server)
        var starts = 0
        uploads.onStart = { starts += 1 }
        var queued = server.queued.makeAsyncIterator()
        var finished = finishes.makeAsyncIterator()

        uploads.send([try file("a.txt", bytes: 5)], to: "!r", replyTo: nil, failure: { Issue.record($0) })
        let first = uploads.progress
        try #require(await queued.next()).states.end(.sent)
        #expect(await finished.next() == true)

        uploads.send([try file("b.txt", bytes: 7)], to: "!r", replyTo: nil, failure: { Issue.record($0) })
        #expect(starts == 2 && uploads.files == 1 && uploads.finished == 0)
        #expect(uploads.progress !== first)
        try #require(await queued.next()).states.end(.sent)
        #expect(await finished.next() == true)
        #expect(uploads.progress.completedUnitCount == 7)
    }
}

private extension AsyncStream<UploadState>.Continuation {
    /// The upload's last state: the core's stream ends with it.
    func end(_ state: UploadState) {
        yield(state)
        finish()
    }
}

/// The uploads over the Rust core's demo account: the core streams a file's upload to the end,
/// and another account's uploads are another's.
@MainActor
@Suite(.closesDemoSessions)
struct DemoUploadsTests {
    @Test func aFileGoesThroughTheCoresStream() async throws {
        let session = DemoSessions.open(rooms: 2, messagesPerRoom: 2)
        let uploads = try #require(session.uploads)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("demo-uploads-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: file)
        let (finishes, finishing) = AsyncStream.makeStream(of: Bool.self)
        uploads.onFinish = { finishing.yield($0) }

        uploads.send([file], to: "!room1:demo", replyTo: nil, failure: { Issue.record($0) })
        var finished = finishes.makeAsyncIterator()
        #expect(await finished.next() == true)
        #expect(uploads.progress.fractionCompleted == 1)
    }

    @Test func closingTheAccountTellsItsUploadsFollowersOfTheChange() async {
        let session = DemoSessions.open(rooms: 2, messagesPerRoom: 2)
        var changes = 0
        let watching = session.uploadsChanges.observe { changes += 1 }
        #expect(session.uploads != nil)
        await session.close()
        #expect(session.uploads == nil && changes == 1)
        withExtendedLifetime(watching) {}
    }
}
