import XCTest

class SnapshotHelper: XCTestCase {
    static func setupSnapshot(_ app: XCUIApplication) {
        app.launchArguments += ["-com.apple.CoreData.ConcurrencyDebug", "0"]
    }
}

// fastlane snapshot stub — replaced at runtime by fastlane scan
func snapshot(_ name: String, timeWaitingForIdle: TimeInterval = 0) {
    #if DEBUG
    print("Screenshot: \(name)")
    #endif
}
