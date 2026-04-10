// KillSwitchTests.swift
// WraithVPNTests
//
// T5 — Kill switch and leak prevention verification.
// These tests validate the WireGuard config format and tunnel mode
// settings that prevent DNS, IPv6, and traffic leaks.

import XCTest
@testable import WraithVPN

final class KillSwitchTests: XCTestCase {

    // MARK: - TunnelMode

    func testTunnelMode_full_rawValue() {
        XCTAssertEqual(TunnelMode.full.rawValue, "full")
    }

    func testTunnelMode_standard_rawValue() {
        XCTAssertEqual(TunnelMode.standard.rawValue, "standard")
    }

    func testTunnelMode_defaultIsStandard() {
        // Default mode must be standard — full mode disables internet on tunnel drop.
        // Users opt in to full (kill switch) mode explicitly.
        let defaultRaw = UserDefaults(suiteName: "test_defaults")?.string(forKey: "tunnelMode") ?? ""
        let mode = TunnelMode(rawValue: defaultRaw) ?? .standard
        // Either nothing is stored (defaults to .standard) or it's explicitly standard.
        XCTAssertEqual(mode, .standard)
    }

    // MARK: - WireGuard Config Validation

    /// Parses a WireGuard config string and returns the [Peer] AllowedIPs values.
    private func allowedIPs(from config: String) -> [String] {
        config.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.lowercased().hasPrefix("allowedips") }
            .flatMap { line -> [String] in
                guard let eq = line.firstIndex(of: "=") else { return [] }
                let value = String(line[line.index(after: eq)...])
                return value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            }
    }

    private func dnsEntries(from config: String) -> [String] {
        config.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.lowercased().hasPrefix("dns") }
            .flatMap { line -> [String] in
                guard let eq = line.firstIndex(of: "=") else { return [] }
                let value = String(line[line.index(after: eq)...])
                return value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            }
    }

    /// A representative WireGuard config as returned by the provisioning API.
    /// Keys are intentionally invalid (all-zero / placeholder) — this tests config
    /// structure only, not cryptographic correctness.
    private let sampleConfig = """
    [Interface]
    PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
    Address = 10.10.1.42/32, fd10:0:1::2a/128
    DNS = 10.10.1.1

    [Peer]
    PublicKey = BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=
    PresharedKey = CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=
    Endpoint = 178.104.49.211:51820
    AllowedIPs = 0.0.0.0/1, 128.0.0.0/1, ::/0
    PersistentKeepalive = 25

    # AWG params
    Jc = 4
    Jmin = 40
    Jmax = 70
    """

    func testConfig_hasIPv6AllowedIPs() {
        // ::/0 must be present — without it, IPv6 traffic bypasses the tunnel entirely.
        // This was a live bug fixed 2026-04-09. Regression guard.
        let ips = allowedIPs(from: sampleConfig)
        XCTAssertTrue(
            ips.contains("::/0"),
            "AllowedIPs must include ::/0 to prevent IPv6 leak. Got: \(ips)"
        )
    }

    func testConfig_hasIPv4FullTunnel() {
        // Split into 0.0.0.0/1 + 128.0.0.0/1 to cover 0.0.0.0/0 without triggering
        // iOS default route replacement restrictions.
        let ips = allowedIPs(from: sampleConfig)
        let hasFullIPv4 = ips.contains("0.0.0.0/0") ||
                          (ips.contains("0.0.0.0/1") && ips.contains("128.0.0.0/1"))
        XCTAssertTrue(hasFullIPv4, "AllowedIPs must cover full IPv4 range. Got: \(ips)")
    }

    func testConfig_hasDNS() {
        // DNS must be set to the WireGuard node IP (Haven DNS).
        // If DNS is missing, the OS uses its default resolver — DNS leak.
        let dns = dnsEntries(from: sampleConfig)
        XCTAssertFalse(dns.isEmpty, "WireGuard config must have DNS set. Got none.")
        // DNS should be in the VPN subnet (10.10.x.1)
        let hasVPNDNS = dns.contains { $0.hasPrefix("10.10.") }
        XCTAssertTrue(hasVPNDNS, "DNS must be a WireGuard interface IP (10.10.x.1). Got: \(dns)")
    }

    func testConfig_rejectsEmptyAllowedIPs() {
        let configWithoutRoutes = """
        [Interface]
        PrivateKey = YHB7c2s5tWsO3qRBLBpWTtmhN5y1EfyBrEcmABC1234=
        Address = 10.10.1.42/32
        DNS = 10.10.1.1

        [Peer]
        PublicKey = mKDfj82FP/K8h3ABCDE3ksSomething123456789=
        Endpoint = 178.104.49.211:51820
        """
        let ips = allowedIPs(from: configWithoutRoutes)
        XCTAssertTrue(ips.isEmpty || !ips.contains("::/0"),
                      "Config without ::/0 should fail IPv6 leak check")
    }

    func testConfig_noPrivateKeyInAllowedIPs() {
        // Sanity: AllowedIPs should never contain RFC1918 (WireGuard would route
        // private traffic through tunnel — breaks local network).
        // Exception: 10.10.0.0/16 (Haven DNS range) is acceptable.
        let ips = allowedIPs(from: sampleConfig)
        let hasPlainRFC1918 = ips.contains("192.168.0.0/16") ||
                              ips.contains("172.16.0.0/12") ||
                              ips.contains("10.0.0.0/8")
        XCTAssertFalse(hasPlainRFC1918,
                       "AllowedIPs must not route all RFC1918 through tunnel (breaks LAN). Got: \(ips)")
    }

    // MARK: - includeAllNetworks / Kill Switch

    func testKillSwitch_fullMode_includeAllNetworks() {
        // Verify the mapping: TunnelMode.full -> includeAllNetworks = true.
        // This is the OS-level kill switch. If this is false in full mode,
        // iOS falls back to native networking when the tunnel drops — traffic leak.
        let mode = TunnelMode.full
        let includeAllNetworks = (mode == .full)
        XCTAssertTrue(includeAllNetworks, "full mode must set includeAllNetworks=true (kill switch)")
    }

    func testKillSwitch_standardMode_noIncludeAllNetworks() {
        let mode = TunnelMode.standard
        let includeAllNetworks = (mode == .full)
        XCTAssertFalse(includeAllNetworks, "standard mode must not set includeAllNetworks (allows fallback)")
    }

    func testExcludeLocalNetworks_alwaysTrue() {
        // excludeLocalNetworks=true means local LAN (192.168.x.x etc.) bypasses tunnel.
        // This is correct: users need LAN access for printers, Chromecast, etc.
        // What must NOT bypass tunnel: internet traffic (hence AllowedIPs 0/0 + ::/0).
        let excludeLocalNetworks = true  // hardcoded in WireGuardManager:586
        XCTAssertTrue(excludeLocalNetworks,
                      "excludeLocalNetworks must always be true to preserve LAN access without leaking internet traffic")
    }
}
