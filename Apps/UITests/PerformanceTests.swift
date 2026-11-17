import XCTest

/// Launch, scrolling and memory, as XCTest measures them (hitch time ratio from the scroll
/// signposts). Demo data by default; `TEST_RUNNER_LUX_REAL=1` uses the signed-in account instead
/// (read only: it opens a chat and scrolls, it sends nothing).
@MainActor
final class PerformanceTests: XCTestCase {
    private var real: Bool { ProcessInfo.processInfo.environment["LUX_REAL"] == "1" }

    private func app() -> XCUIApplication {
        let app = XCUIApplication()
        if !real { app.launchArguments = ["-LuxDemo"] }
        return app
    }

    override func setUp() { continueAfterFailure = false }

    func testLaunch() {
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)]) { app().launch() }
    }

    func testScrollChatList() {
        let app = app()
        app.launch()
        let list = app.collectionViews["chats"]
        XCTAssertTrue(list.cells.firstMatch.waitForExistence(timeout: 30))
        let options = XCTMeasureOptions()
        options.invocationOptions = [.manuallyStop]
        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric, XCTMemoryMetric(application: app)], options: options) {
            list.swipeUp(velocity: .fast)
            list.swipeUp(velocity: .fast)
            list.swipeUp(velocity: .fast)
            stopMeasuring()
            list.swipeDown(velocity: .fast)
            list.swipeDown(velocity: .fast)
            list.swipeDown(velocity: .fast)
        }
    }

    func testScrollChat() {
        let app = app()
        app.launch()
        let list = app.collectionViews["chats"]
        XCTAssertTrue(list.cells.firstMatch.waitForExistence(timeout: 30))
        list.cells.element(boundBy: real ? 0 : 1).tap()
        let messages = app.collectionViews["messages"]
        XCTAssertTrue(messages.cells.firstMatch.waitForExistence(timeout: 30))
        let options = XCTMeasureOptions()
        options.invocationOptions = [.manuallyStop]
        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric, XCTMemoryMetric(application: app)], options: options) {
            // towards older messages (and, with an account, pages of history from the server).
            messages.swipeDown(velocity: .fast)
            messages.swipeDown(velocity: .fast)
            messages.swipeDown(velocity: .fast)
            stopMeasuring()
            messages.swipeUp(velocity: .fast)
            messages.swipeUp(velocity: .fast)
            messages.swipeUp(velocity: .fast)
        }
    }
}
