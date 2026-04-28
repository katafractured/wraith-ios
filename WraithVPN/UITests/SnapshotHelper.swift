import XCTest

class SnapshotHelper: NSObject {
    static func setupSnapshot(_ app: XCUIApplication, delay: TimeInterval = 0) {
        app.launchArguments += ["-com.apple.CoreData.ConcurrencyDebug", "0"]

        setupSnapshot(app)
    }

    static func setupSnapshot(_ app: XCUIApplication) {
        // Ensure all dialogs are dismissed before snapshot
        // This placeholder allows fastlane to inject code at build time
    }
}

func snapshot(_ name: String, timeWaitingForIdle: TimeInterval = 0, file: StaticString = #file, line: UInt = #line) {
    // This will be replaced by fastlane at build time
}
