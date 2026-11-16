import Testing
@testable import LuxCore

/// The demo sessions a test opens close as it ends (their search's work ended, their stores
/// closed): none is left to close as the test process exits. A suite that opens them takes
/// `.closesDemoSessions` and opens them with `DemoSessions.open`.
@MainActor
final class DemoSessions {
    @TaskLocal static var opened: DemoSessions?
    private var sessions: [Session] = []

    /// A demo session that closes as the test ends.
    static func open(rooms: Int, messagesPerRoom: Int, encryption: Session.DemoEncryption = .ready,
                     verificationRequestAfter: Int? = nil) -> Session {
        let session = Session.demo(rooms: rooms, messagesPerRoom: messagesPerRoom, encryption: encryption,
                                   verificationRequestAfter: verificationRequestAfter)
        guard let opened else {
            Issue.record("a demo session opened outside .closesDemoSessions")
            return session
        }
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
        let opened = DemoSessions()
        try await DemoSessions.$opened.withValue(opened) { try await function() }
        await opened.close()
    }
}

extension Trait where Self == ClosesDemoSessions {
    /// The demo sessions each test opens close as it ends.
    static var closesDemoSessions: Self { ClosesDemoSessions() }
}
