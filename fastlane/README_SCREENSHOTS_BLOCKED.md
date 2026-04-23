# Screenshot workflow blocked: missing XCUITest target

**Doctrine:** `feedback_screenshots_never_manual.md` — every UI change must auto-refresh screenshots.

This repo has `fastlane/` + `.github/workflows/screenshots.yml` wired but the
`WraithVPNUITests` XCUITest target does not exist yet. The workflow will fail
until the test target is created.

## To unblock

1. Create a new XCUITest target in the Xcode project (File > New > Target > UI Testing Bundle).
2. Name it `WraithVPNUITests`.
3. Add capture tests using fastlane's `snapshot()` helper — see Vault's
   `VaultyxUITests/VaultyxScreenshotTests.swift` as a template.
4. Add a `ScreenshotMode.swift` launch-argument hook so tests can set
   mocked data / skip onboarding.
5. Commit the test target, workflow will start producing screenshots.
