import Foundation
import Testing
@testable import LuxCore

/// The uploads over their port alone: a file goes to its chat's queue, its upload followed as
/// the core streams it; what cannot go reaches the chat that sent it; the account's end ends them.
@MainActor
@Suite(.ownFolder, .timeLimit(.minutes(1)))
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

    private let folder: URL

    init() throws {
        folder = try TemporaryFolder.ofTest
    }

    /// A text file of `bytes` bytes, picked to send.
    private func file(_ name: String, bytes: Int) throws -> URL {
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
        let (progressed, progressing) = AsyncStream.makeStream(of: Int64.self)
        uploads.onProgress = { [weak uploads] in progressing.yield(uploads?.progress.completedUnitCount ?? 0) }

        uploads.send([try file("a.txt", bytes: 100), try file("b.txt", bytes: 300)], to: "!r", caption: "Both", replyTo: "$q",
                     failure: { Issue.record($0) })
        #expect(starts == 1 && uploads.files == 2 && uploads.isActive)
        let first = try await server.queued.first()
        let second = try await server.queued.first()
        // the caption and the answer go with the first file alone.
        #expect((first.name, first.caption, first.replyTo) == ("a.txt", "Both", "$q"))
        #expect((second.name, second.caption, second.replyTo) == ("b.txt", nil, nil))

        first.states.yield(.uploading(0.5))
        _ = try await progressed.first { $0 == 50 }
        #expect(uploads.progress.totalUnitCount == 400)
        first.states.end(.sent)
        second.states.yield(.uploading(1))
        second.states.end(.sent)

        #expect(try await finishes.first() == true)
        #expect(uploads.finished == 2 && !uploads.isActive)
        #expect(uploads.progress.fractionCompleted == 1)
    }

    @Test func aFileOverTheServersLimitReachesTheChatAndIsNotSent() async throws {
        let server = Server(limit: 10)
        let (uploads, finishes, failures, report) = uploads(over: server)
        uploads.send([try file("large.txt", bytes: 11)], to: "!r", replyTo: nil, failure: report)

        let failure = try await failures.first()
        #expect(failure.localizedDescription == AttachmentMaker.Failure.tooLarge(name: "large.txt", limit: 10).localizedDescription)
        #expect(try await finishes.first() == false)
        #expect(uploads.finished == 1)
    }

    @Test func aPastedPictureOverTheServersLimitReachesTheChatUnderItsName() async throws {
        let server = Server(limit: 10)
        let (uploads, finishes, failures, report) = uploads(over: server)
        let pasted = try await PastedItems.files([.data(Data(repeating: 0x61, count: 11), type: .png, name: nil)], in: folder)
        uploads.send(pasted, to: "!r", replyTo: nil, failure: report)

        let failure = try await failures.first()
        #expect(failure.localizedDescription == AttachmentMaker.Failure.tooLarge(name: "Pasted Image.png", limit: 10).localizedDescription)
        #expect(try await finishes.first() == false)
    }

    @Test func aFileTheQueueRefusesReachesTheChat() async throws {
        let (uploads, finishes, failures, report) = uploads(over: Server(refusal: Refused()))
        uploads.send([try file("a.txt", bytes: 5)], to: "!r", replyTo: nil, failure: report)

        #expect(try await failures.first() as? Refused == Refused())
        #expect(try await finishes.first() == false)
    }

    @Test func anUploadThatFailsEndsTheBatchNotAllThrough() async throws {
        let server = Server()
        let (uploads, finishes, _, _) = uploads(over: server)
        uploads.send([try file("a.txt", bytes: 5)], to: "!r", replyTo: nil, failure: { Issue.record($0) })
        let sent = try await server.queued.first()
        // the chat shows it failed, with its retry: no error besides.
        sent.states.end(.failed)

        #expect(try await finishes.first() == false)
    }

    @Test func aDiscardedFileIsThroughWithoutFailing() async throws {
        let server = Server()
        let (uploads, finishes, _, _) = uploads(over: server)
        uploads.send([try file("a.txt", bytes: 5)], to: "!r", replyTo: nil, failure: { Issue.record($0) })
        try await server.queued.first().states.finish()

        #expect(try await finishes.first() == true)
    }

    @Test func closingWithTheAccountStopsFollowingAndEndsTheBatch() async throws {
        let server = Server()
        let (uploads, finishes, _, _) = uploads(over: server)
        uploads.send([try file("a.txt", bytes: 5)], to: "!r", replyTo: nil, failure: { Issue.record($0) })
        _ = try await server.queued.first()

        // over when it returns: the batch ended, and nothing follows the upload any more.
        await uploads.close()
        #expect(try await finishes.first() == false)
        #expect(!uploads.isActive)
        try await server.unfollowed.first()
    }

    @Test func sendingAfterAllWentStartsAFreshBatch() async throws {
        let server = Server()
        let (uploads, finishes, _, _) = uploads(over: server)
        var starts = 0
        uploads.onStart = { starts += 1 }

        uploads.send([try file("a.txt", bytes: 5)], to: "!r", replyTo: nil, failure: { Issue.record($0) })
        let first = uploads.progress
        try await server.queued.first().states.end(.sent)
        #expect(try await finishes.first() == true)

        uploads.send([try file("b.txt", bytes: 7)], to: "!r", replyTo: nil, failure: { Issue.record($0) })
        #expect(starts == 2 && uploads.files == 1 && uploads.finished == 0)
        #expect(uploads.progress !== first)
        try await server.queued.first().states.end(.sent)
        #expect(try await finishes.first() == true)
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
@Suite(.closesDemoSessions, .timeLimit(.minutes(1)))
struct DemoUploadsTests {
    @Test func aFileGoesThroughTheCoresStream() async throws {
        let session = try DemoSessions.open(rooms: 2, messagesPerRoom: 2)
        let uploads = try #require(session.uploads)
        let file = try TemporaryFolder.ofTest.appending(path: "notes.txt")
        try Data("hello".utf8).write(to: file)
        let (finishes, finishing) = AsyncStream.makeStream(of: Bool.self)
        uploads.onFinish = { finishing.yield($0) }

        uploads.send([file], to: "!room1:demo", replyTo: nil, failure: { Issue.record($0) })
        #expect(try await finishes.first() == true)
        #expect(uploads.progress.fractionCompleted == 1)
    }

    @Test func closingTheAccountTellsItsUploadsFollowersOfTheChange() async throws {
        let session = try DemoSessions.open(rooms: 2, messagesPerRoom: 2)
        var changes = 0
        let watching = session.uploadsChanges.observe { changes += 1 }
        #expect(session.uploads != nil)
        await session.close()
        #expect(session.uploads == nil && changes == 1)
        withExtendedLifetime(watching) {}
    }
}
