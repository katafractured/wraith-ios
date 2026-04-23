// ScreenshotMode — Katafract per-app screenshot infrastructure (Layer 1)
//
// Activated via launch arguments passed by fastlane snapshot or XCUITest:
//   --screenshots               (master switch — enables all overrides)
//   --mock-subscribed           (force isSubscribed = true)
//   --mock-unsubscribed         (force isSubscribed = false — for paywall capture)
//   --skip-onboarding           (bypass onboarding gates)
//   --force-onboarding          (force onboarding flow)

import Foundation

enum ScreenshotMode {
    static var isActive: Bool { args.contains("--screenshots") }
    static var mockSubscribed: Bool   { isActive && args.contains("--mock-subscribed") }
    static var mockUnsubscribed: Bool { isActive && args.contains("--mock-unsubscribed") }
    static var skipOnboarding: Bool   { isActive && args.contains("--skip-onboarding") }
    static var forceOnboarding: Bool  { isActive && args.contains("--force-onboarding") }

    private static var args: [String] { ProcessInfo.processInfo.arguments }
}
