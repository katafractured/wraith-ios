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
    static var mockConnected: Bool { isActive && args.contains("--mock-connected") }
    static var mockDisconnectedAdvanced: Bool { isActive && args.contains("--mock-disconnected-advanced") }
    static var mockRegions: Bool { isActive && args.contains("--mock-regions") }
    static var mockHavenPrefs: Bool { isActive && args.contains("--mock-haven-prefs") }
    static var mockDnsStats: Bool { isActive && args.contains("--mock-dns-stats") }
    static var paywallSovereignAnnual: Bool { isActive && args.contains("--paywall-sovereign-annual") }

    private static var args: [String] { ProcessInfo.processInfo.arguments }
}
