import XCTest

@MainActor
final class WraithVPNScreenshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testCapture01Hero() {
        let app = launch(flags: [
            "--screenshots", "--skip-onboarding", "--mock-subscribed", "--mock-connected",
        ])
        sleep(4)
        snapshot("01_hero")
    }

    func testCapture02Operator() {
        let app = launch(flags: [
            "--screenshots", "--force-onboarding",
        ])
        sleep(3)
        snapshot("02_operator")
    }

    func testCapture03Regions() {
        let app = launch(flags: [
            "--screenshots", "--skip-onboarding", "--mock-subscribed", "--mock-regions",
        ])
        let regionButton = app.buttons.matching(identifier: "region-button").firstMatch
        if regionButton.waitForExistence(timeout: 5) {
            regionButton.tap()
            sleep(3)
        }
        snapshot("03_regions")
    }

    func testCapture04Haven() {
        let app = launch(flags: [
            "--screenshots", "--skip-onboarding", "--mock-subscribed", "--mock-haven-prefs",
        ])
        let settingsTab = app.buttons.matching(identifier: "settings-tab").firstMatch
        if settingsTab.waitForExistence(timeout: 5) {
            settingsTab.tap()
        }
        let havenRow = app.buttons.matching(identifier: "haven-row").firstMatch
        if havenRow.waitForExistence(timeout: 5) {
            havenRow.tap()
            sleep(3)
        }
        snapshot("04_haven")
    }

    func testCapture05Stats() {
        let app = launch(flags: [
            "--screenshots", "--skip-onboarding", "--mock-subscribed", "--mock-dns-stats",
        ])
        let settingsTab = app.buttons.matching(identifier: "settings-tab").firstMatch
        if settingsTab.waitForExistence(timeout: 5) {
            settingsTab.tap()
        }
        let statsRow = app.buttons.matching(identifier: "stats-row").firstMatch
        if statsRow.waitForExistence(timeout: 5) {
            statsRow.tap()
            sleep(3)
        }
        snapshot("05_stats")
    }

    func testCapture06Paywall() {
        let app = launch(flags: [
            "--screenshots", "--skip-onboarding", "--mock-unsubscribed", "--paywall-sovereign-annual",
        ])
        sleep(4)
        snapshot("06_paywall")
    }

    func testCapture07KillSwitch() {
        let app = launch(flags: [
            "--screenshots", "--skip-onboarding", "--mock-subscribed", "--mock-disconnected-advanced",
        ])
        sleep(4)
        snapshot("07_killswitch")
    }

    // MARK: - Helpers

    private func launch(flags: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        SnapshotHelper.setupSnapshot(app)
        app.launchArguments += flags
        app.launch()
        return app
    }
}
