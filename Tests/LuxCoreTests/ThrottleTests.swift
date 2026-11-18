import Foundation
import Testing
@testable import LuxCore

/// The throttle on a clock the test moves: the newest work runs at most once per interval, never
/// two at once, and no test waits for real time.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ThrottleTests {
    private let clock = TestClock()
    /// What ran, in order: "a" as work a starts, "a done" as it ends.
    private let ran: AsyncStream<String>
    private let running: AsyncStream<String>.Continuation

    init() {
        (ran, running) = AsyncStream.makeStream()
    }

    private func work(_ name: String) -> () async -> Void {
        { [running] in running.yield(name) }
    }

    @Test func theFirstWorkRunsAtOnceAndOnlyTheNewestOfWhatCameMeanwhileRunsAfterTheInterval() async throws {
        let throttle = Throttle(interval: .seconds(2), clock: clock)
        throttle.schedule(work("a"))
        #expect(try await ran.first() == "a")
        _ = try await clock.sleeps.first()
        throttle.schedule(work("b"))
        throttle.schedule(work("c"))
        clock.advance(by: .seconds(2))
        // b was dropped: the next to run is c.
        #expect(try await ran.first() == "c")
        withExtendedLifetime(throttle) {}
    }

    @Test func workAfterAQuietIntervalRunsAtOnce() async throws {
        let throttle = Throttle(interval: .seconds(2), clock: clock)
        throttle.schedule(work("a"))
        #expect(try await ran.first() == "a")
        _ = try await clock.sleeps.first()
        clock.advance(by: .seconds(2))
        throttle.schedule(work("b"))
        #expect(try await ran.first() == "b")
        withExtendedLifetime(throttle) {}
    }

    @Test func workNeverStartsBeforeTheOneBeforeItEnds() async throws {
        let throttle = Throttle(interval: .seconds(2), clock: clock)
        let slow = Held<String, Void>()
        throttle.schedule { [running] in
            running.yield("a")
            await slow.answer(for: "a")
            running.yield("a done")
        }
        #expect(try await ran.first() == "a")
        throttle.schedule(work("b"))
        // the interval passes while a still runs.
        clock.advance(by: .seconds(10))
        #expect(try await slow.asks.first() == "a")
        await slow.answer("a")
        #expect(try await ran.first() == "a done")
        _ = try await clock.sleeps.first()
        clock.advance(by: .seconds(2))
        #expect(try await ran.first() == "b")
        withExtendedLifetime(throttle) {}
    }
}
