import Foundation
import LuxCore
import Testing

/// A demo session of the test's own, as `Tests/LuxCoreTests` opens one: its files in a temporary
/// folder and its settings in a defaults suite, both gone, and the session closed, as the test
/// ends, also when it stops at a failed wait. The host app's own session (`-LuxDemo`) is another.
@MainActor
enum DemoAccount {
    static func with(rooms: Int = 40, messagesPerRoom: Int = 5,
                     _ test: (Session) async throws -> Void) async throws {
        let name = "lux-view-tests-\(UUID().uuidString)"
        let folder = FileManager.default.temporaryDirectory.appending(path: name, directoryHint: .isDirectory)
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let session = Session.demo(rooms: rooms, messagesPerRoom: messagesPerRoom, encryption: .ready, verificationRequestAfter: nil,
                                   folder: folder, preferences: Preferences(defaults: defaults))
        do {
            try await test(session)
        } catch {
            await close(session, folder)
            throw error
        }
        await close(session, folder)
    }

    private static func close(_ session: Session, _ folder: URL) async {
        await session.close()
        do {
            try FileManager.default.removeItem(at: folder)
        } catch {
            Issue.record(error, "the test's folder stays")
        }
    }
}
