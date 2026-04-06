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

    // MARK: - Init

    init() {
        Task { await refreshStatus() }
    }

    // MARK: - Public

    func enable() async {
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            let manager = NEDNSSettingsManager.shared()
            try await manager.loadFromPreferences()

            // If profile is installed but deactivated (e.g. device set back to Automatic),
            // remove it first so iOS re-activates on the next save.
            if manager.dnsSettings != nil && !manager.isEnabled {
                try await manager.removeFromPreferences()
                try await manager.loadFromPreferences()
            }

            let settings = NEDNSOverHTTPSSettings(servers: [])
            settings.serverURL = URL(string: dohURL)
            manager.dnsSettings = settings
            manager.localizedDescription = profileDescription

            try await manager.saveToPreferences()
            // Set optimistically — the immediate loadFromPreferences round-trip can
            // return stale state before iOS has fully activated the profile.
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
            preferences = try await APIClient.shared.fetchDnsPreferences()
        } catch {
            loadPreferencesError = preferences == nil  // only flag error if we have nothing to show
        }
    }

    func updatePreferences(_ update: DnsPreferencesUpdate) async throws {
        isUpdatingPreferences = true
        defer { isUpdatingPreferences = false }
        preferences = try await APIClient.shared.updateDnsPreferences(update)
    }
}
