// HavenDNSManager.swift
// WraithVPN
//
// Manages the Haven DNS-over-HTTPS profile using NEDNSSettingsManager.
// Haven DNS is available for free — no subscription required.
// It installs a system DNS profile that routes all DNS queries through
// Katafract's WraithGate nodes (AdGuard Home, blocking ads + trackers).

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
    private let prefsKey = "havenDnsPreferences"

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

    func enable() async {
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            let manager = NEDNSSettingsManager.shared()
            try await manager.loadFromPreferences()

            // Already enabled — nothing to do.
            if manager.isEnabled {
                isEnabled = true
                return
            }

            // Remove stale disabled profile if one exists. Use try? so a removal
            // hiccup doesn't block installing a fresh profile.
            if manager.dnsSettings != nil {
                try? await manager.removeFromPreferences()
            }

            // Install fresh profile.
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
            // Clear any stale enable error now that we've confirmed current state.
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

    /// Enables Haven DNS profile if the user has a subscription and it isn't already active.
    func ensureEnabledForSubscriber() async {
        guard KeychainHelper.shared.readOptional(for: .subscriptionToken) != nil else { return }
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
