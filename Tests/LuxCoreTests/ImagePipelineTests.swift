import Foundation
import Testing
@testable import LuxCore

/// The images' pipeline as the account closes: its folder goes right after, so nothing may be
/// written in it once the close returned.
@MainActor
@Suite(.ownFolder, .timeLimit(.minutes(1)))
struct ImagePipelineTests {
    @Test func closingWaitsForTheImagesLoadingAndLoadsNoMore() async throws {
        let folder = try TemporaryFolder.ofTest.appending(path: "media", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let account = RustAccount.demo(rooms: 2, messagesPerRoom: 1)
        let images = ImagePipeline(account: Task { account }, directory: folder)
        // the demo draws each chat's picture into the folder as it loads: once the first is
        // written, the others are loading.
        let writes = try FolderWrites(folder)
        let loads = (0..<64).map { index in
            Task { await images.image(.room(id: "!room\(index):demo", version: ""), pixels: 40) }
        }
        await writes.next()
        await images.close()
        let written = files(in: folder)
        for load in loads { _ = await load.value }
        #expect(files(in: folder) == written)
        #expect(await images.image(.room(id: "!late:demo", version: ""), pixels: 40) == nil)
    }

    private func files(in folder: URL) -> Set<String> {
        Set(FileManager.default.subpaths(atPath: folder.path) ?? [])
    }
}

/// A folder's changes (a file written in it), as the system tells them: nothing polls.
private final class FolderWrites {
    private let source: any DispatchSourceFileSystemObject
    private let changes: AsyncStream<Void>

    init(_ folder: URL) throws {
        let descriptor = open(folder.path, O_EVTONLY)
        try #require(descriptor >= 0, "the folder cannot be watched")
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .global())
        let (changes, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.changes = changes
        source.setEventHandler { continuation.yield() }
        source.setCancelHandler { close(descriptor) }
        source.activate()
    }

    deinit { source.cancel() }

    /// Returns at the folder's next change.
    func next() async {
        for await _ in changes { return }
    }
}
