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
        sleep(1) // let the tab switch settle before tapping a row
        firstCell.tap()
        if !detailIsShown(app) {
            firstCell.tap()
        }
        XCTAssertTrue(detailIsShown(app), "cell detail did not open")
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

    private func detailIsShown(_ app: XCUIApplication) -> Bool {
        let titles = ["5G cell", "LTE cell", "UMTS cell", "GSM cell"]
        let deadline = Date().addingTimeInterval(5)
        repeat {
            if titles.contains(where: { app.navigationBars[$0].exists }) { return true }
            usleep(250_000)
        } while Date() < deadline
        return false
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
