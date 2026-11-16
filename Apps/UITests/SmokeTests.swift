import XCTest

/// The demo account (`-LuxDemo`, no server) walked through what a tester does first: a chat,
/// search, Settings, and the app sent to the background and back. Fails on a crash (the app no
/// longer running in the foreground) or a hang: every step waits at most `hang` for its screen,
/// and a main thread that does not answer leaves the screen unreached. CI runs it on a simulator.
@MainActor
final class SmokeTests: XCTestCase {
    private let hang: TimeInterval = 10
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-LuxDemo"]
        app.launch()
    }

    func testDemoWalkthrough() {
        // the chat list, then a chat.
        let chats = app.collectionViews["chats"]
        // the first launch may wait for the store; 30 s, as PerformanceTests.
        XCTAssertTrue(chats.cells.firstMatch.waitForExistence(timeout: 30), "the chat list did not show")
        alive("launch")
        chats.cells.element(boundBy: 1).tap()
        reach(app.collectionViews["messages"].cells.firstMatch, "a chat's messages")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        reach(chats, "the chat list, back from the chat")

        // search: the toolbar's button, a query, its results.
        let searchButton = app.buttons["Search"].firstMatch
        reach(searchButton, "the search button")
        searchButton.tap()
        let field = app.searchFields.firstMatch
        reach(field, "the search field")
        field.typeText("hello")
        reach(app.collectionViews["search-results"], "search's results")
        alive("search")
        // closing search: the field's close button (its label is the system's, lowercase).
        let close = app.buttons.matching(NSPredicate(format: "label ==[c] 'close'")).firstMatch
        reach(close, "search's close button")
        close.tap()
        reach(chats, "the chat list, back from search")

        // Settings.
        let settings = app.navigationBars.buttons["Settings"].firstMatch
        reach(settings, "the Settings button")
        settings.tap()
        alive("Settings")
        reach(app.navigationBars["Settings"], "Settings")

        // the background and back: what iOS does to the app between two uses (0xdead10cc kills
        // happen here, when the app holds a lock in its group's container as it is suspended).
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: hang) || app.state == .runningBackgroundSuspended,
                      "the app did not go to the background")
        // a moment suspended, as the watchdog sees it.
        sleep(3)
        XCTAssertNotEqual(app.state, .notRunning, "the app was killed in the background")
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: hang), "the app did not come back")
        reach(app.navigationBars["Settings"], "Settings, back from the background")
    }

    /// Waits for what a step shows, and fails on a crash or a hang.
    private func reach(_ element: XCUIElement, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        alive(what, file: file, line: line)
        XCTAssertTrue(element.waitForExistence(timeout: hang), "\(what) did not show within \(Int(hang)) s",
                      file: file, line: line)
        alive(what, file: file, line: line)
    }

    private func alive(_ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(app.state, .runningForeground, "the app crashed (at \(what))", file: file, line: line)
    }
}
