import Foundation
import Testing
@testable import LuxCore

/// The iPhone's reading while it charges, over a made-up task, reader and device: who reads (the
/// front or the task, never both), how the system taking the time back, the app coming to the
/// front and the device's conditions end a task, and that it ends once and asks for another only
/// while something is left.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct BackgroundReadingTests {
    /// The system's task: its ends, and its expiry for the test to call.
    final class Time: BackgroundTime {
        private(set) var completions: [Bool] = []
        private var expire: (@MainActor () -> Void)?
        let changes = Changes()

        func onExpiry(_ expire: @escaping @MainActor () -> Void) {
            self.expire = expire
        }

        func complete(success: Bool) {
            completions.append(success)
            changes.send()
        }

        /// The system takes the time back.
        func expireNow() {
            expire?()
        }
    }

    final class Requests: BackgroundRequests {
        private(set) var submitted = 0
        private(set) var cancelled = 0

        func submit() throws { submitted += 1 }
        func cancel() { cancelled += 1 }
    }

    final class Conditions: WorkConditions {
        var reason: String? { didSet { changed?() } }
        private var changed: (@MainActor () -> Void)?

        func observe(_ changed: @escaping @MainActor () -> Void) -> AnyObject {
            self.changed = changed
            return self
        }
    }

    /// Reads under the window of `work` until the test lets it end (`finish`) or the work is
    /// cancelled; what happened, in order, in `events`.
    final class Reader: BackgroundReader {
        private let work: LongWork
        var opens = true
        var workLeft = true
        private(set) var events: [String] = []
        let changes = Changes()
        private var finishing: AsyncStream<Bool>.Continuation?

        init(work: LongWork) {
            self.work = work
        }

        func begin() async -> Bool {
            note("begin")
            return opens
        }

        func read() async -> Bool {
            let (answers, finishing) = AsyncStream<Bool>.makeStream()
            self.finishing = finishing
            let done = await work.run("made-up reading") { [weak self] _ -> Bool? in
                await self?.note("reading")
                // cancelled (the window closed), the stream ends without an answer.
                for await done in answers { return done }
                return nil
            } ?? nil
            note(done == nil ? "read stopped" : "read")
            return done ?? false
        }

        /// The reading ends: `done` when nothing is left.
        func finish(done: Bool) {
            workLeft = !done
            finishing?.yield(done)
        }

        func end() async {
            note("end")
        }

        func hasWorkLeft() async -> Bool {
            workLeft
        }

        private func note(_ event: String) {
            events.append(event)
            changes.send()
        }
    }

    let work: LongWork
    let reader: Reader
    let requests = Requests()
    let conditions = Conditions()
    let reading: BackgroundReading
    let time = Time()

    init() {
        work = LongWork(inFront: false)
        reader = Reader(work: work)
        reading = BackgroundReading(work: work, reader: reader, requests: requests, conditions: conditions)
    }

    @Test("a task the system starts while the app is in front leaves the reading to the front")
    func inFront() async throws {
        work.enter()
        reading.start(time)
        #expect(time.completions == [true])
        #expect(reader.events.isEmpty)
    }

    @Test("a task reads what is left, ends once, and asks for another while something is left")
    func readsAndAsksAgain() async throws {
        reading.start(time)
        try await reader.changes.until { reader.events.contains("reading") }
        #expect(work.isActive, "the window is open while it reads")
        reader.finish(done: false)
        try await time.changes.until { !time.completions.isEmpty }
        #expect(time.completions == [false])
        #expect(reader.events == ["begin", "reading", "read", "end"])
        #expect(requests.submitted == 1)
        #expect(!work.isActive, "no work starts once the task has ended")
    }

    @Test("a task that read everything ends successfully and asks for none")
    func readsEverything() async throws {
        reading.start(time)
        try await reader.changes.until { reader.events.contains("reading") }
        reader.finish(done: true)
        try await time.changes.until { !time.completions.isEmpty }
        #expect(time.completions == [true])
        #expect(requests.submitted == 0)
        #expect(requests.cancelled == 1)
    }

    @Test("the system taking the time back stops the reading, waits for it, closes, then ends the task once")
    func expiry() async throws {
        reading.start(time)
        try await reader.changes.until { reader.events.contains("reading") }
        time.expireNow()
        time.expireNow()
        try await time.changes.until { !time.completions.isEmpty }
        #expect(time.completions == [false])
        #expect(reader.events == ["begin", "reading", "read stopped", "end"])
        #expect(requests.submitted == 1, "the rest is read the next time")
        #expect(!work.isActive)
    }

    @Test("the app coming to the front takes the reading over: the task ends, the reading goes on once")
    func handOver() async throws {
        reading.start(time)
        try await reader.changes.until { reader.events.contains("reading") }
        work.enter()
        #expect(time.completions == [true])
        #expect(work.isActive)
        reader.finish(done: true)
        try await reader.changes.until { reader.events.contains("end") }
        #expect(reader.events == ["begin", "reading", "read", "end"], "read once, not stopped, not read again")
        #expect(time.completions == [true])
        #expect(work.isActive, "the front's work goes on")
    }

    @Test("a second task while one runs ends at once and reads nothing")
    func oneAtATime() async throws {
        reading.start(time)
        try await reader.changes.until { reader.events.contains("reading") }
        let second = Time()
        reading.start(second)
        #expect(second.completions == [false])
        reader.finish(done: true)
        try await time.changes.until { !time.completions.isEmpty }
        #expect(reader.events.filter { $0 == "begin" }.count == 1)
    }

    @Test("nothing to read for (signed out, or the keychain locked before the first unlock): no reading, the task ends")
    func nothingToReadFor() async throws {
        reader.opens = false
        reading.start(time)
        try await time.changes.until { !time.completions.isEmpty }
        #expect(time.completions == [false])
        #expect(reader.events == ["begin", "end"])
    }

    @Test("Low Power Mode, Low Data Mode or heat: no task reads, and one under way stops")
    func conditionsStopTheReading() async throws {
        conditions.reason = "Low Power Mode"
        reading.start(time)
        #expect(time.completions == [false])
        #expect(reader.events.isEmpty)

        conditions.reason = nil
        let next = Time()
        reading.start(next)
        try await reader.changes.until { reader.events.contains("reading") }
        conditions.reason = "the device is hot"
        try await next.changes.until { !next.completions.isEmpty }
        #expect(next.completions == [false])
        #expect(reader.events == ["begin", "reading", "read stopped", "end"])
    }

    @Test("a task is asked for only while something is left to read")
    func schedulesOnlyWithWorkLeft() async {
        reader.workLeft = false
        await reading.schedule()
        #expect(requests.submitted == 0)
        #expect(requests.cancelled == 1)
        reader.workLeft = true
        await reading.schedule()
        #expect(requests.submitted == 1)
    }
}
