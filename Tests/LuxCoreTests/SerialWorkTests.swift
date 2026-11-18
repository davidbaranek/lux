import Testing
@testable import LuxCore

/// Work one piece at a time, as the search model's loads run: never two at once, however many ask
/// together; waiting for the work stops only once it has ended; a piece cancelled before its turn
/// never starts.
@Suite(.timeLimit(.minutes(1)))
struct SerialWorkTests {
    /// What the pieces did, in order.
    private actor Log {
        private(set) var lines: [String] = []
        private var running = 0
        private(set) var mostAtOnce = 0

        func add(_ line: String) { lines.append(line) }

        func start() {
            running += 1
            mostAtOnce = max(mostAtOnce, running)
        }

        func end() { running -= 1 }
    }

    @Test func piecesAskedTogetherRunOneAtATime() async throws {
        let work = SerialWork()
        let log = Log()
        try await withThrowingTaskGroup { group in
            for _ in 0..<20 {
                group.addTask {
                    try await work.run {
                        await log.start()
                        // suspended in the middle, as a model's load is: the next one still waits.
                        for _ in 0..<5 { await Task.yield() }
                        await log.end()
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(await log.mostAtOnce == 1)
    }

    @Test func waitingForTheWorkEndsOnlyAfterThePieceUnderWay() async throws {
        let work = SerialWork()
        let log = Log()
        let held = Held<String, Void>()
        let piece = Task {
            try await work.run {
                await held.answer(for: "load")
                await log.add("loaded")
            }
        }
        _ = try await held.asks.first()
        let idle = Task {
            await work.idle()
            await log.add("idle")
        }
        await held.answer("load")
        try await piece.value
        await idle.value
        #expect(await log.lines == ["loaded", "idle"])
    }

    @Test func aPieceCancelledBeforeItsTurnNeverStarts() async throws {
        let work = SerialWork()
        let log = Log()
        let held = Held<String, Void>()
        let first = Task { try await work.run { await held.answer(for: "first") } }
        _ = try await held.asks.first()
        let second = Task { try await work.run { await log.add("second") } }
        second.cancel()
        await held.answer("first")
        try await first.value
        await #expect(throws: CancellationError.self) { try await second.value }
        await work.idle()
        #expect(await log.lines.isEmpty)
    }
}
