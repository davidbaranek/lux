import Foundation
import Testing
@testable import LuxCore

/// The app's long work runs in front or in a background task's window, and ends when neither is.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct LongWorkTests {
    /// Runs work under `work` that waits until it is cancelled, and says whether it was.
    private func waitingWork(_ work: LongWork) -> (started: AsyncStream<Void>, ended: Task<Bool?, Never>) {
        let (started, starting) = AsyncStream<Void>.makeStream()
        let ended = Task {
            await work.run("waits") { _ in
                starting.yield()
                try? await Task.sleep(for: .seconds(3600))
                return Task.isCancelled
            }
        }
        return (started, ended)
    }

    @Test("leaving the front cancels the long work and waits for it to end")
    func leavingCancels() async throws {
        let work = LongWork(inFront: true)
        let (started, ended) = waitingWork(work)
        _ = try await started.first()
        await work.leave()
        #expect(await ended.value == true)
        #expect(!work.isActive)
    }

    @Test("leaving with a window open leaves its work going; closing the window ends it")
    func windowKeepsTheWork() async throws {
        let work = LongWork(inFront: false)
        #expect(work.openWindow {})
        let (started, ended) = waitingWork(work)
        _ = try await started.first()
        await work.leave()
        #expect(work.isActive)
        await work.closeWindow()
        #expect(await ended.value == true)
        #expect(!work.isActive)
    }

    @Test("no window opens while the app is in front, and coming to the front closes one")
    func windowOnlyAway() async {
        let work = LongWork(inFront: true)
        #expect(!work.openWindow {})
        await work.leave()
        var handedOver = false
        #expect(work.openWindow { handedOver = true })
        #expect(!work.openWindow {}, "one window at a time")
        work.enter()
        #expect(handedOver)
        #expect(work.isActive)
    }
}
