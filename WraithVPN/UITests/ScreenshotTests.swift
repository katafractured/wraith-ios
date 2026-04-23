import XCTest

@MainActor
final class WraithVPNScreenshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testCaptureHeroOnboarding() {
        let app = launch(flags: [
            "--screenshots", "--force-onboarding", "--mock-subscribed",
        ])
        sleep(4)
        snapshot("01_hero")
    }

    func testCaptureRegionPicker() {
        let app = launch(flags: defaultFlags)
        sleep(3)
        let regionButton = app.buttons.matching(identifier: "region-button").firstMatch
        if regionButton.waitForExistence(timeout: 5) {
            regionButton.tap()
            sleep(2)
        }
        snapshot("02_regions")
    }

    func testCaptureConnectedState() {
        let app = launch(flags: [
            "--screenshots", "--skip-onboarding", "--mock-subscribed",
        ])
        sleep(3)
        let connectButton = app.buttons.matching(identifier: "connect-button").firstMatch
        if connectButton.waitForExistence(timeout: 5) {
            connectButton.tap()
            sleep(3)
        }
        snapshot("03_connected")
    }

    func testCaptureHavenTierPicker() {
        let app = launch(flags: defaultFlags)
        sleep(3)
        let havensButton = app.buttons.matching(identifier: "haven-button").firstMatch
        if havensButton.waitForExistence(timeout: 5) {
            havensButton.tap()
            sleep(2)
        }
        snapshot("04_haven_tiers")
    }

    func testCapturePaywallV2() {
        let app = launch(flags: [
            "--screenshots", "--skip-onboarding", "--mock-unsubscribed",
        ])
        sleep(3)
        triggerPaywall(app: app)
        sleep(3)
        snapshot("05_paywall_enclave_sovereign")
    }

    func testCaptureSettings() {
        let app = launch(flags: defaultFlags)
        sleep(3)
        let settingsTab = app.buttons.matching(identifier: "settings-tab").firstMatch
        if settingsTab.waitForExistence(timeout: 5) {
            settingsTab.tap()
            sleep(2)
        }
        snapshot("06_settings_transport")
    }

    // MARK: - Helpers

    private var defaultFlags: [String] {
        ["--screenshots", "--skip-onboarding", "--mock-subscribed"]
    }

    private func launch(flags: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        SnapshotHelper.setupSnapshot(app)
        app.launchArguments += flags
        app.launch()
        return app
    }

    private func triggerPaywall(app: XCUIApplication) {
        let upgradeButton = app.buttons.matching(identifier: "upgrade-button").firstMatch
        if upgradeButton.waitForExistence(timeout: 5) {
            upgradeButton.tap()
            return
        }
        let paywallButton = app.buttons["Upgrade"].firstMatch
        if paywallButton.waitForExistence(timeout: 3) {
            paywallButton.tap()
        }
    }
}
