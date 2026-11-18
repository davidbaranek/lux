import Foundation
import Synchronization
import Testing
@testable import LuxCore

/// Each test's files (its stores, pictures, a demo session's folders) are in a temporary folder of
/// its own, which goes with all in it as the test ends, also when the test throws. A suite that
/// makes files takes `.ownFolder` (`.closesDemoSessions` gives it too) and makes them in
/// `TemporaryFolder.ofTest`; a store it opens with `TemporaryFolder.store` closes before the
/// folder goes.
final class TemporaryFolder: Sendable {
    @TaskLocal fileprivate static var current: TemporaryFolder?
    fileprivate let url: URL
    private let stores = Mutex<[LocalStore]>([])

    fileprivate init(url: URL) {
        self.url = url
    }

    /// The running test's folder (`.ownFolder`).
    static var ofTest: URL {
        get throws { try #require(current, "a file made outside .ownFolder").url }
    }

    /// A store in the test's folder, new unless `name` names one opened before; it closes as the
    /// test ends.
    static func store(named name: String = UUID().uuidString,
                      key: String = String(repeating: "ef", count: 32)) async throws -> LocalStore {
        let folder = try #require(current, "a store opened outside .ownFolder")
        let store = try await LocalStore.open(file: storeFile(named: name), key: key)
        folder.stores.withLock { $0.append(store) }
        return store
    }

    /// The file of the store `name` in the test's folder.
    static func storeFile(named name: String) throws -> URL {
        try ofTest.appending(path: "\(name).sqlite")
    }

    /// Closes the test's stores and removes the folder with all in it. A task the test started
    /// keeps its task-local values, this folder among them: the folder lets its stores go, so a
    /// store lives no longer than what uses it.
    fileprivate func remove() async {
        let opened = stores.withLock { stores in
            defer { stores = [] }
            return stores
        }
        for store in opened { await store.close() }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            Issue.record(error, "the test's folder stays")
        }
    }
}

struct OwnFolder: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?,
                      performing function: @Sendable () async throws -> Void) async throws {
        // once per test, also under two traits that give it.
        guard testCase != nil, TemporaryFolder.current == nil else { return try await function() }
        let folder = TemporaryFolder(url: FileManager.default.temporaryDirectory
            .appending(path: "lux-tests-\(UUID().uuidString)", directoryHint: .isDirectory))
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        // a test stopped by a failed wait leaves no file either.
        do {
            try await TemporaryFolder.$current.withValue(folder) { try await function() }
        } catch {
            await folder.remove()
            throw error
        }
        await folder.remove()
    }
}

extension Trait where Self == OwnFolder {
    /// Each test's files are in a folder of its own, which goes as the test ends.
    static var ownFolder: Self { OwnFolder() }
}
