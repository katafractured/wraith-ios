// HavenDNSManager.swift
// WraithVPN
//
// Manages the Haven DNS-over-HTTPS profile using NEDNSSettingsManager.
// Haven DNS is available for free — no subscription required.
// It installs a system DNS profile that routes all DNS queries through
// Katafract's WraithGate nodes (AdGuard Home, blocking ads + trackers).
//
// IMPORTANT — single profile contract:
//   - NEDNSSettingsManager.shared() is a per-app singleton: only ONE DNS profile
//     can exist per app at any time. Never call removeFromPreferences() followed
//     by saveToPreferences() — iOS treats that as a new profile and shows the
//     user a second approval prompt.
//   - The profile is NEVER toggled in response to VPN state. It stays installed
//     and active through VPN connect/disconnect/switch cycles. DoH requests queue
//     during the ~2s tunnel restart window and complete when the tunnel is up.
//     Removing the profile during VPN connect causes a 30s DNS blackout (kill
//     switch blocks all traffic including DNS until the profile is reinstalled).

import Foundation
import NetworkExtension
import Combine

@MainActor
final class HavenDNSManager: ObservableObject {

    // MARK: - Published

    @Published var isEnabled: Bool = false
    @Published var isLoading: Bool = false
    @Published var error: String? = nil
    @Published var preferences: DnsPreferences? = nil
    @Published var isUpdatingPreferences: Bool = false
    @Published var isLoadingPreferences: Bool = false
    @Published var loadPreferencesError: Bool = false

    // MARK: - Private

    private let dohURL = "https://dns.katafract.com/dns-query"
    private let profileDescription = "Haven DNS — Ad & tracker blocking by WraithVPN"

    // MARK: - Init

    init() {
        preferences = Self.loadCachedPreferences()
        Task { await refreshStatus() }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(serverDidChange),
            name: .vpnServerDidChange,
            object: nil
        )
    }

    @objc private func serverDidChange() {
        Task { await loadPreferences() }
    }

    // MARK: - Public

    /// Installs (or updates in-place) the Haven DNS-over-HTTPS profile.
    /// Shows the iOS system approval prompt on first install; subsequent calls
    /// update the existing profile silently.
    func enable() async {
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            let manager = NEDNSSettingsManager.shared()
            try await manager.loadFromPreferences()

            // Already installed and active — nothing to do.
            if manager.isEnabled {
                isEnabled = true
                return
            }

            // Update or install the profile in-place.
            // Do NOT call removeFromPreferences() first — that causes iOS to treat
            // the next save as a brand-new profile, showing a second approval prompt
            // and creating a duplicate visible in Settings.
            let settings = NEDNSOverHTTPSSettings(servers: [])
            settings.serverURL = URL(string: dohURL)
            manager.dnsSettings = settings
            manager.localizedDescription = profileDescription

            try await manager.saveToPreferences()
            isEnabled = true
        } catch {
            self.error = "Could not enable Haven DNS: \(error.localizedDescription)"
            await refreshStatus()
        }
    }

    /// Removes the Haven DNS profile. Only call this in response to an explicit
    /// user action — never call it automatically on VPN state changes.
    func disable() async {
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            let manager = NEDNSSettingsManager.shared()
            try await manager.loadFromPreferences()
            try await manager.removeFromPreferences()
            isEnabled = false
        } catch {
            self.error = "Could not disable Haven DNS: \(error.localizedDescription)"
        }
    }

    func toggle() async {
        if isEnabled { await disable() } else { await enable() }
    }

    func refreshStatus() async {
        let manager = NEDNSSettingsManager.shared()
        do {
            try await manager.loadFromPreferences()
            isEnabled = manager.isEnabled
            if isEnabled { error = nil }
        } catch {
            isEnabled = false
        }
    }

    func loadPreferences() async {
        guard KeychainHelper.shared.readOptional(for: .subscriptionToken) != nil else { return }
        isLoadingPreferences = true
        loadPreferencesError = false
        defer { isLoadingPreferences = false }
        do {
            let fetched = try await APIClient.shared.fetchDnsPreferences()
            preferences = fetched
            Self.cachePreferences(fetched)
            await applyDefaultsIfNeeded(fetched)
        } catch {
            loadPreferencesError = preferences == nil
        }
    }

    /// On first load for a paid user, ensure safe browsing is on and protection is at least Low.
    private func applyDefaultsIfNeeded(_ prefs: DnsPreferences) async {
        let key = "havenDefaultsApplied"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)

        var update = DnsPreferencesUpdate()
        if prefs.protectionLevel == "NONE" {
            update.protectionLevel = "LOW"
        }
        if prefs.isPro && !prefs.safeBrowsing {
            update.safeBrowsing = true
        }
        guard update.protectionLevel != nil || update.safeBrowsing != nil else { return }
        try? await updatePreferences(update)
    }

    /// Enables Haven DNS profile if the user has any active entitlement.
    func ensureEnabledForSubscriber(hasPurchased: Bool = false) async {
        let hasToken = KeychainHelper.shared.readOptional(for: .subscriptionToken) != nil
        guard hasToken || hasPurchased else { return }
        await refreshStatus()
        if !isEnabled { await enable() }
    }

    func updatePreferences(_ update: DnsPreferencesUpdate) async throws {
        isUpdatingPreferences = true
        defer { isUpdatingPreferences = false }
        let updated = try await APIClient.shared.updateDnsPreferences(update)
        preferences = updated
        Self.cachePreferences(updated)
    }

    // MARK: - Cache helpers

    private static func cachePreferences(_ prefs: DnsPreferences) {
        if let data = try? JSONEncoder().encode(prefs) {
            UserDefaults.standard.set(data, forKey: "havenDnsPreferences")
        }
    }

    private static func loadCachedPreferences() -> DnsPreferences? {
        guard let data = UserDefaults.standard.data(forKey: "havenDnsPreferences") else { return nil }
        return try? JSONDecoder().decode(DnsPreferences.self, from: data)
    }
}
