import Foundation
import Testing
@testable import LuxCore

/// Each test's settings are its own, in a defaults suite that goes as the test ends: no test reads
/// or writes the app's (`UserDefaults.standard`), and tests side by side never share theirs. A
/// suite that needs them takes `.ownPreferences` (`.closesDemoSessions` gives them too) and reads
/// `Preferences.ofTest`.
struct OwnPreferences: SuiteTrait, TestTrait, TestScoping {
    @TaskLocal fileprivate static var current: Preferences?

    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?,
                      performing function: @Sendable () async throws -> Void) async throws {
        // once per test, also under two traits that give them.
        guard testCase != nil, Self.current == nil else { return try await function() }
        let suite = "lux-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = try await Self.preferences(in: suite)
        try await Self.$current.withValue(preferences) { try await function() }
    }

    /// Settings kept in `suite`, made on the main actor, where they are read.
    @MainActor
    private static func preferences(in suite: String) throws -> Preferences {
        Preferences(defaults: try #require(UserDefaults(suiteName: suite)))
    }
}

extension Trait where Self == OwnPreferences {
    /// Each test's settings are its own, and go as it ends.
    static var ownPreferences: Self { OwnPreferences() }
}

extension Preferences {
    /// The running test's own settings (`.ownPreferences`).
    nonisolated static var ofTest: Preferences {
        get throws { try #require(OwnPreferences.current, "settings read outside .ownPreferences") }
    }
}
