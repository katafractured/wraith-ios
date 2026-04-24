# Wraith VPN — App Store screenshot narrative spec v1

Curator: Opus. Scope: App Store listing screenshots for iPhone 17 Pro Max (6.9") and iPad Pro 13" M5. Same 7-frame storyline on both devices. No retired brand names. No external-checkout copy. No cross-app mentions.

Implementation note for the Haiku worker: this file is the spec, not the code. Only touch `WraithVPN/UITests/ScreenshotTests.swift`, `WraithVPN/App/ScreenshotMode.swift`, and a small number of views where an `accessibilityIdentifier` needs to exist. `fastlane/Snapfile` already has the correct devices, launch args, and status-bar overrides; do not modify it.

## 1. Narrative thesis

The listing has to do one job in the first two frames: convince someone who already distrusts NordVPN / Express / Surfshark that this is the operator-grade tool they've been looking for. Frame 1 is the hero — the connected Enclave state, gold hairline, sealed-ledger typography, real exit IP, no generic "shield with checkmark." Frame 2 is the value proposition in one sentence: WraithGates, our own fleet, no third parties. Frame 3 proves it's real infrastructure by showing the region list with distinct cities. Frame 4 is the differentiator no big VPN has: Haven DNS is built in, not a bolt-on. Frame 5 shows the Haven blocking receipts so the claim is verifiable. Frame 6 is the Sovereign upsell (multi-hop + full Enclave platform) placed late so the pitch is earned, not front-loaded. Frame 7 is the closer — the kill switch + no-logs posture that operator-minded buyers scan for before purchase.

Seven frames, not eight. Eight starts to dilute; six leaves the upsell exposed without proof. Seven is the right count for this brand.

## 2. Frame-by-frame spec

| # | Scene (Swift View) | State / mock data | Headline (≤35) | Subtitle (≤60) | Rationale |
|---|---|---|---|---|---|
| 01 | `ConnectView` — connected | `vpn.status = .connected`, server = Frankfurt DE, `vpn.exitIP = "178.104.49.211"`, `connectedSince = 3m42s ago`, single-hop, subscribed. Gold hairline border visible. Status reads "Inside the Enclave." | Inside the Enclave. | WireGuard tunnel to our own fleet. No third parties. | Hero. Signature brand moment — gold ledger aesthetic, not green-checkmark VPN ad. |
| 02 | `OnboardingView` page 1 (`OnboardingPrivacy`) | Onboarding page 0, `eyebrow: "PRIVATE ACCESS"`, blue accent. Full-bleed. | You don't connect. You operate. | Private traffic. Clear boundaries. Your own perimeter. | Brand statement. Tagline adapted to listing-safe length. Sets operator tone early. |
| 03 | `RegionPickerView` | Region list loaded with 9 regions matching live fleet: Frankfurt DE, Helsinki FI, Ashburn US, Hillsboro US, Newark US, Singapore SG, Tokyo JP, Mumbai IN, Hillsboro US-2. No "Coming soon" rows. ISO tiles only. | Nine regions. Continuously expanding. | WraithGates we own and operate — never rented nodes. | Proves it's a real fleet, not a middleman. Aligns with "global expansion framing" doctrine. |
| 04 | `HavenDNSSettingsView` | Protection level = Standard selected, Strict visible but unselected. Safe browsing ON, Family filter OFF. Subscribed tier, no locked-state banner. | DNS filtering, on by default. | Haven blocks ads, trackers, malware before they load. | Haven-as-built-in is the moat. Settings view reads as real product, not a feature list. |
| 05 | `DnsStatsView` | `blockRatePercent = 14.3`, `totalQueries = 48217`, `since = "April 17"`. Category row: Ads 4,128 · Trackers 2,536 · Malware 187. 7-day history bar chart populated. | 48,217 queries. Verified blocked. | Receipts, not marketing. Every block counted at the DNS layer. | Proof. Operator buyers want numbers. Headline uses real mock counter. |
| 06 | `PaywallView` | `selectedTier = .sovereign`, annual toggle ON. Shows Enclave $64/yr + Sovereign $144/yr tiers side-by-side with Sovereign highlighted. Token-entry link visible; no external URLs rendered. | Two tiers. One Enclave. | Enclave: VPN + Haven. Sovereign: add multi-hop. | Upsell placed after proof. Uses only live v2 tier names. No retired tiers, no cross-app bundles. |
| 07 | `ConnectView` — disconnected, advanced mode | `vpn.status = .disconnected`, `simpleMode = false`, `vpn.tunnelMode = .full` (Kill Switch ON), selected server = Tokyo JP, subscribed. Route pill + Mode pill + Kill Switch pill all visible. | Kill switch on. No logs. | If the tunnel drops, the traffic drops. That's the contract. | Closer. Hits the two phrases operator buyers search for: "kill switch" and "no logs." |

## 3. Visual + design notes

Mock state is provided via `ScreenshotMode` flags consumed at manager init. Never touch production network paths. Status bar is already normalized by the Snapfile — do not re-normalize in-app.

- **01 Hero** — flag `--mock-connected`: `WireGuardManager` publishes `status=.connected`, `exitIP="178.104.49.211"`, `assignedIP="10.10.1.14"`, `connectedSince = now − 222s`, `connectedServer = mock Frankfurt (🇩🇪, "Frankfurt", nodeId "nbg1-demo")`, `isMultiHop=false`, `isHavenOnly=false`. Gold hairline border must render.
- **02 Operator** — reuses `--force-onboarding`. Lands on page 0; no taps.
- **03 Regions** — flag `--mock-regions`: `ServerListManager` returns a deterministic 9-region array in this order — Frankfurt DE, Helsinki FI, Ashburn US, Hillsboro US, Newark US, Singapore SG, Tokyo JP, Mumbai IN, Hillsboro-2 US. Pings 30–180 ms. No loading spinner.
- **04 Haven** — flag `--mock-haven-prefs`: `HavenDNSManager.preferences = { protectionLevel: .standard, safeBrowsing: true, familyFilter: false, blockedServices: [] }`, not Haven-only.
- **05 Stats** — flag `--mock-dns-stats`: `DnsStatsResponse { totalQueries: 48217, blockedQueries: 6891, blockRatePercent: 14.3, since: "April 17", categories: { ads: 4128, trackers: 2536, malware: 187, adult: 40 }, history: 7-day curve (weekend dip, mid-week peak) }`.
- **06 Paywall** — `--mock-unsubscribed` + `--paywall-sovereign-annual` (sets `selectedTier=.sovereign`, `showAnnual=true` in `onAppear`). `storeKit.products` stubbed with v2 prices ($8/$64 · $18/$144) when `ScreenshotMode.isActive`.
- **07 Kill switch** — flag `--mock-disconnected-advanced`: pre-launch sets `UserDefaults simpleMode=false`; `WireGuardManager.status=.disconnected`, `tunnelMode=.full`, `servers.selectedServer = mock Tokyo (🇯🇵, "Tokyo", nodeId "nrt1-demo")`, subscribed. All three summary pills render.

## 4. What NOT to show

1. **No AchievementsView.** Its source still contains a retired brand id (`veil_connected`) and gamification reads wrong for this operator audience. Suppress entirely from the listing until the IDs are cleaned up.
2. **No CodeRedemptionView / hidden 7-tap path.** That sheet is for offer codes — Apple doesn't want it in marketing screenshots and it confuses the narrative.
3. **No DebugLogView, no DnsStatsView raw logs, no assignedIP + exitIP both shown.** One IP per frame, exit IP only, never the tunnel-internal `10.10.x.x` assigned IP.
4. **No Shadowsocks / obfuscation / AmneziaWG / wg0 references.** SS is parked (see memory `project_wraith_shadowsocks_parked_2026_04_23`). The standard wg1 path is the only one we show.
5. **No retired names anywhere in subtitles or mock data:** "VPN Armor", "DNS Armor", "DNS Pro", "NetArmor", "Veil", "Katafract Total", "Enclave Plus", "Haven Pro", "Haven paid." Also never say "also unlocks Vaultyx/DocArmor/etc" — Wraith's listing stands alone (Apple 3.1.1).

## 5. Post-curator hand-off — exact edits for the Haiku worker

**A. `WraithVPN/App/ScreenshotMode.swift` — extend**

Add these static accessors alongside the existing ones (same `args.contains` pattern):

- `mockConnected`
- `mockDisconnectedAdvanced`
- `mockRegions`
- `mockHavenPrefs`
- `mockDnsStats`
- `paywallSovereignAnnual`

**B. Mock injection points — read `ScreenshotMode.*` at init and return fake state when active.** Touch only:

- `WraithGuardManager` init: honor `mockConnected` / `mockDisconnectedAdvanced`.
- `ServerListManager.refresh()`: short-circuit the 9-region array when `mockRegions`.
- `HavenDNSManager.loadPreferences()`: short-circuit with mock prefs when `mockHavenPrefs`.
- `DnsStatsView.load()`: short-circuit with mock stats when `mockDnsStats`.
- `StoreKitManager`: inject stub products at v2 prices when `ScreenshotMode.isActive`; honor `mockSubscribed` / `mockUnsubscribed`.
- `PaywallView.onAppear`: if `paywallSovereignAnnual`, set `selectedTier=.sovereign`, `showAnnual=true`.
- `WraithVPNApp`: before body renders, set `UserDefaults simpleMode` to `false` for `mockDisconnectedAdvanced`, `true` for `mockConnected`.

**C. Accessibility identifiers — attach, do not rename:**

- `ConnectView` header Settings NavigationLink → `"settings-tab"`
- `ConnectView.serverButton` → `"region-button"`
- `ConnectView.connectButton` ZStack → `"connect-button"`
- `SettingsView` Haven DNS row → `"haven-row"`; Protection Stats row → `"stats-row"`
- `PaywallView` primary CTA → `"upgrade-button"`

**D. `WraithVPN/UITests/ScreenshotTests.swift` — replace the six existing test methods with seven tests in this exact order and naming, all using `snapshot("NN_slug")`:**

1. `testCapture01Hero` — flags: `--screenshots --skip-onboarding --mock-subscribed --mock-connected`. `sleep(4)`. Snapshot `01_hero`. No taps.
2. `testCapture02Operator` — flags: `--screenshots --force-onboarding`. `sleep(3)`. Snapshot `02_operator`. No taps (lands on page 0).
3. `testCapture03Regions` — flags: `--screenshots --skip-onboarding --mock-subscribed --mock-regions`. Tap `region-button` (wait 5s for existence), `sleep(3)`. Snapshot `03_regions`.
4. `testCapture04Haven` — flags: `--screenshots --skip-onboarding --mock-subscribed --mock-haven-prefs`. Tap `settings-tab` → tap `haven-row`, `sleep(3)`. Snapshot `04_haven`.
5. `testCapture05Stats` — flags: `--screenshots --skip-onboarding --mock-subscribed --mock-dns-stats`. Tap `settings-tab` → tap `stats-row`, `sleep(3)`. Snapshot `05_stats`.
6. `testCapture06Paywall` — flags: `--screenshots --skip-onboarding --mock-unsubscribed --paywall-sovereign-annual`. `sleep(4)`. Snapshot `06_paywall`. No taps (unsubscribed users land directly on paywall).
7. `testCapture07KillSwitch` — flags: `--screenshots --skip-onboarding --mock-subscribed --mock-disconnected-advanced`. `sleep(4)`. Snapshot `07_killswitch`. No taps.

Retain `launch(flags:)` helper. Delete `triggerPaywall(app:)` — no longer needed. Delete `testCaptureSettings` and `testCapturePaywallV2` (replaced).

**E. `fastlane/Snapfile` — no changes.** Devices (`iPhone 17 Pro Max`, `iPad Pro 13-inch (M5)`), `ios_version("26.4")`, `languages(["en-US"])`, launch args, and status bar override are already correct.

**F. Localized copy — not this PR.** The seven headlines + subtitles above are English-only. Localization is a separate task; the worker should not add fastlane `framefile.json` or `title.strings` files in this pass.

## Acceptance criteria

- 7 screenshots produced per device class, named `01_hero`…`07_killswitch`.
- Every frame renders deterministic mock state — no network calls, no loading spinners visible.
- No retired brand strings anywhere in the rendered output or mock data.
- `fastlane snapshot` succeeds on both device classes without human intervention.
- Listing copy (headlines + subtitles) is baked into the Fastlane `frameit`/metadata upload step separately; not part of the XCUITest.
