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

        // Open a cell from the latest-measurement card on the Live tab.
        let latestCard = app.buttons["latestCell"]
        XCTAssertTrue(latestCard.waitForExistence(timeout: 5), "latest measurement card missing")
        latestCard.tap()
        XCTAssertTrue(detailIsShown(app), "cell detail did not open from the Live card")
        sleep(1)
        snapshot("3-CellDetail")
        app.swipeUp()
        app.swipeUp()
        snapshot("4-CellDetail-Location")
        app.navigationBars.buttons.element(boundBy: 0).tap() // back to Live

        // Open a cell from the Cells list.
        app.tabBars.buttons["Cells"].tap()
        let row = app.buttons["cellRow"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "cell list is empty")
        snapshot("2-Cells")
        row.tap()
        let listNavigationWorks = detailIsShown(app)
        if !listNavigationWorks {
            for line in app.debugDescription.split(separator: "\n").prefix(80) { print("TOUR: \(line)") }
        }
        XCTAssertTrue(listNavigationWorks, "cell detail did not open from the Cells list")

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
