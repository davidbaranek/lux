import Foundation
import Testing

/// What a fake port was asked, held until the test answers it: the test sees each ask as it comes
/// (`asks`) and decides when it gets its answer, so an older ask can be answered after a newer one,
/// as a slow server answers.
actor Held<Ask: Hashable & Sendable, Answer: Sendable> {
    /// Each ask, as the fake gets it.
    nonisolated let asks: AsyncStream<Ask>
    private let asking: AsyncStream<Ask>.Continuation
    private var waiting: [Ask: CheckedContinuation<Answer, Never>] = [:]

    init() {
        (asks, asking) = AsyncStream.makeStream()
    }

    /// The fake's side: waits for the test's answer to `ask`.
    func answer(for ask: Ask) async -> Answer {
        await withCheckedContinuation { continuation in
            waiting[ask] = continuation
            asking.yield(ask)
        }
    }

    /// The test's side: answers `ask`, which the fake was asked and still waits on.
    func answer(_ ask: Ask, with answer: Answer, sourceLocation: SourceLocation = #_sourceLocation) {
        guard let continuation = waiting.removeValue(forKey: ask) else {
            Issue.record("\(ask) was not asked", sourceLocation: sourceLocation)
            return
        }
        continuation.resume(returning: answer)
    }
}

extension Held where Answer == Void {
    func answer(_ ask: Ask, sourceLocation: SourceLocation = #_sourceLocation) {
        answer(ask, with: (), sourceLocation: sourceLocation)
    }
}
