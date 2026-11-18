import Foundation
import Testing
@testable import LuxCore

/// The demo sessions a test opens close as it ends (their search's work ended, their stores
/// closed): none is left to close as the test process exits. A suite that opens them takes
/// `.closesDemoSessions` and opens them with `DemoSessions.open`. Their settings are the test's
/// own (`.ownPreferences`), and their files are in the test's folder (`.ownFolder`).
@MainActor
final class DemoSessions {
    @TaskLocal static var opened: DemoSessions?
    private var sessions: [Session] = []

    /// A demo session that closes as the test ends.
    static func open(rooms: Int, messagesPerRoom: Int, encryption: Session.DemoEncryption = .ready,
                     verificationRequestAfter: Int? = nil) throws -> Session {
        let opened = try #require(opened, "a demo session opened outside .closesDemoSessions")
        let session = Session.demo(rooms: rooms, messagesPerRoom: messagesPerRoom, encryption: encryption,
                                   verificationRequestAfter: verificationRequestAfter,
                                   folder: try TemporaryFolder.ofTest.appending(path: UUID().uuidString, directoryHint: .isDirectory),
                                   preferences: try Preferences.ofTest)
        opened.sessions.append(session)
        return session
    }

    fileprivate func close() async {
        for session in sessions { await session.close() }
        sessions = []
    }
}

struct ClosesDemoSessions: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?,
                      performing function: @Sendable () async throws -> Void) async throws {
        guard testCase != nil else { return try await function() }
        // the sessions close before the test's settings and files go.
        try await OwnPreferences().provideScope(for: test, testCase: testCase) {
            try await OwnFolder().provideScope(for: test, testCase: testCase) {
                let opened = DemoSessions()
                // a test stopped by a failed wait closes its sessions too.
                do {
                    try await DemoSessions.$opened.withValue(opened) { try await function() }
                } catch {
                    await opened.close()
                    throw error
                }
                await opened.close()
            }
        }
    }
}

extension Trait where Self == ClosesDemoSessions {
    /// The demo sessions each test opens close as it ends.
    static var closesDemoSessions: Self { ClosesDemoSessions() }
}
