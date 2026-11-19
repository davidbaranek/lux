import Testing
@testable import LuxCore

/// Runs `work` as long work, as the app runs it, and gives what it gives.
func leased<Value: Sendable>(_ work: @escaping @Sendable (WorkLease) async throws -> Value) async throws -> Value {
    let result = await LongWork.shared.run("test") { lease -> Result<Value, any Error> in
        do { return .success(try await work(lease)) } catch { return .failure(error) }
    }
    return try #require(result).get()
}
