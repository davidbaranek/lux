/// Async work one piece at a time, in the order it was asked for: each piece starts once the one
/// before it has ended, suspended in between or not (an actor alone lets the next call in at each
/// `await`). A piece whose task is cancelled while it waits for its turn does not start.
actor SerialWork {
    private var isBusy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    nonisolated func run<T>(_ work: () async throws -> sending T) async throws -> sending T {
        await enter()
        do {
            try Task.checkCancellation()
            let result = try await work()
            await leave()
            return result
        } catch {
            await leave()
            throw error
        }
    }

    /// Waits until every piece asked for so far has ended.
    func idle() async {
        await enter()
        leave()
    }

    private func enter() async {
        guard isBusy else {
            isBusy = true
            return
        }
        // `leave` hands the turn on: still busy, the next one's.
        await withCheckedContinuation { waiting.append($0) }
    }

    private func leave() {
        if waiting.isEmpty { isBusy = false } else { waiting.removeFirst().resume() }
    }
}
