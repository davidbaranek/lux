import Foundation

/// Runs work whose failure nobody can act on (tidying a temporary folder, a prefetch, a count for
/// a progress line) and logs the failure instead of dropping it. Work whose failure the user
/// should see throws up or goes to the model's `onError`; this is only for the rest.
///
/// Returns the result, or nil when the work failed. Cancellation is the expected end of a task,
/// so it is not logged.
@discardableResult
public func bestEffort<T>(_ what: String, _ work: () throws -> T) -> T? {
    do { return try work() } catch { logFailure(what, error); return nil }
}

@discardableResult
public func bestEffort<T>(_ what: String, isolation: isolated (any Actor)? = #isolation,
                          _ work: () async throws -> T) async -> T? {
    do { return try await work() } catch { logFailure(what, error); return nil }
}

private func logFailure(_ what: String, _ error: any Error) {
    guard !(error is CancellationError) else { return }
    Log.app.error("\(what, privacy: .public): \(String(describing: error), privacy: .public)")
}
