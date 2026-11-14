import XCTest

/// Launches the app with synthetic data and visits every screen. Catches launch/runtime crashes
/// and leaves screenshots in the test results (exported as a CI artifact).
final class AppTourUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testTourWithDemoData() {
        let app = XCUIApplication()
        app.launchArguments = ["-demoData"]
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["Live"].waitForExistence(timeout: 10))
        snapshot("1-Live")

        app.tabBars.buttons["Cells"].tap()
        let firstCell = app.collectionViews.cells.element(boundBy: 0)
        XCTAssertTrue(firstCell.waitForExistence(timeout: 5), "cell list is empty")
        snapshot("2-Cells")
        firstCell.tap()
        _ = app.navigationBars.element(boundBy: 0).waitForExistence(timeout: 5)
        sleep(1)
        snapshot("3-CellDetail")
        app.swipeUp()
        snapshot("4-CellDetail-Location")

        app.tabBars.buttons["Map"].tap()
        sleep(3)
        snapshot("5-Map")

        app.tabBars.buttons["Insights"].tap()
        sleep(1)
        snapshot("6-Insights")
        app.swipeUp()
        snapshot("7-Insights-Charts")

        app.tabBars.buttons["Settings"].tap()
        snapshot("8-Settings")

        app.tabBars.buttons["Live"].tap()
        app.swipeUp()
        let importButton = app.buttons["Import screenshots"]
        if importButton.waitForExistence(timeout: 3), importButton.isHittable {
            importButton.tap()
            sleep(1)
            snapshot("9-Import")
        }
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
