// MacHavenDNSSettingsView.swift
// WraithVPNMac
//
// macOS port of HavenDNSSettingsView. Form-based native Mac layout.

import SwiftUI
import KatafractStyle

struct MacHavenDNSSettingsView: View {

    @EnvironmentObject var haven:    HavenDNSManager
    @EnvironmentObject var storeKit: StoreKitManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Haven DNS Filters")
                    .font(KFFont.heading(16))
                    .foregroundStyle(.white)
                Spacer()
                Button("Done") { dismiss() }
                    .foregroundStyle(Color.kfAccentBlue)
                    .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.kfSurface)

            Divider().background(Color.kfBorder)

            Group {
                if let prefs = haven.preferences {
                    Form {
                        // Protection Level
                        Section("Protection Level") {
                            ForEach(MacProtectionLevel.allCases, id: \.self) { level in
                                let available = prefs.protectionLevels.contains(level.rawValue)
                                let selected  = prefs.protectionLevel == level.rawValue
                                HStack {
                                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selected ? Color.kfAccentBlue : Color.kfTextMuted)
                                    VStack(alignment: .leading, spacing: 1) {
                                        HStack(spacing: 6) {
                                            Text(level.label)
                                                .foregroundStyle(available ? Color.primary : Color.kfTextMuted)
                                            if !available {
                                                Text("PRO")
                                                    .font(.system(size: 9, weight: .bold))
                                                    .foregroundStyle(Color.kfAccentBlue)
                                                    .padding(.horizontal, 4)
                                                    .padding(.vertical, 1)
                                                    .background(Color.kfAccentBlue.opacity(0.15))
                                                    .clipShape(Capsule())
                                            }
                                        }
                                        Text(level.description)
                                            .font(.system(size: 11))
                                            .foregroundStyle(Color.kfTextMuted)
                                    }
                                    Spacer()
                                    if !available {
                                        Image(systemName: "lock.fill")
                                            .font(.system(size: 11))
                                            .foregroundStyle(Color.kfTextMuted)
                                    }
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    guard available else { return }
                                    Task { try? await haven.updatePreferences(DnsPreferencesUpdate(protectionLevel: level.rawValue)) }
                                }
                                .disabled(!available || haven.isUpdatingPreferences)
                            }
                        }

                        // Advanced
                        Section("Advanced Filtering") {
                            let safeLocked = prefs.protectionLevel == "NONE"
                            Toggle(isOn: Binding(
                                get: { prefs.safeBrowsing },
                                set: { v in Task { try? await haven.updatePreferences(DnsPreferencesUpdate(safeBrowsing: v)) } }
                            )) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("Safe Browsing")
                                    Text("Blocks malware, phishing, and deceptive sites")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Color.kfTextMuted)
                                }
                            }
                            .disabled(safeLocked || haven.isUpdatingPreferences)

                            Toggle(isOn: Binding(
                                get: { prefs.familyFilter },
                                set: { v in Task { try? await haven.updatePreferences(DnsPreferencesUpdate(familyFilter: v)) } }
                            )) {
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack {
                                        Text("Family Filter")
                                        if !prefs.isPro {
                                            Text("PRO")
                                                .font(.system(size: 9, weight: .bold))
                                                .foregroundStyle(Color.kfAccentBlue)
                                                .padding(.horizontal, 4)
                                                .padding(.vertical, 1)
                                                .background(Color.kfAccentBlue.opacity(0.15))
                                                .clipShape(Capsule())
                                        }
                                    }
                                    Text("Blocks adult content")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Color.kfTextMuted)
                                }
                            }
                            .disabled(!prefs.isPro || haven.isUpdatingPreferences)
                        }

                        // Block Services
                        if prefs.isPro {
                            Section("Block Services") {
                                ForEach(MacServiceCategory.allCases, id: \.label) { category in
                                    let services = category.services.filter { prefs.blockableServices.contains($0.id) }
                                    if !services.isEmpty {
                                        DisclosureGroup(category.label) {
                                            ForEach(services, id: \.id) { service in
                                                let isBlocked = prefs.blockedServices.contains(service.id)
                                                Toggle(isOn: Binding(
                                                    get: { isBlocked },
                                                    set: { _ in
                                                        var updated = prefs.blockedServices
                                                        if isBlocked { updated.removeAll { $0 == service.id } }
                                                        else { updated.append(service.id) }
                                                        Task { try? await haven.updatePreferences(DnsPreferencesUpdate(blockedServices: updated)) }
                                                    }
                                                )) {
                                                    Label(service.label, systemImage: "circle.fill")
                                                }
                                                .disabled(haven.isUpdatingPreferences)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .formStyle(.grouped)
                } else if haven.loadPreferencesError {
                    VStack(spacing: 12) {
                        Text("Couldn't load settings")
                            .foregroundStyle(.white)
                        Button("Retry") { Task { await haven.loadPreferences() } }
                            .foregroundStyle(Color.kfAccentBlue)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    HStack { Spacer(); KataProgressRing(); Spacer() }
                        .frame(maxHeight: .infinity)
                }
            }
        }
        .frame(width: 440)
        .frame(minHeight: 480)
        .background(Color.kfBackground)
        .preferredColorScheme(.dark)
        .task { await haven.loadPreferences() }
    }
}

// MARK: - Protection level enum (Mac copy, avoids file visibility issues)

private enum MacProtectionLevel: String, CaseIterable {
    case off      = "NONE"
    case low      = "LOW"
    case standard = "STANDARD"
    case high     = "HIGH"
    case family   = "FAMILY"

    var label: String {
        switch self {
        case .off:      return "Off"
        case .low:      return "Low"
        case .standard: return "Standard"
        case .high:     return "High"
        case .family:   return "Family"
        }
    }

    var description: String {
        switch self {
        case .off:      return "No filtering."
        case .low:      return "Blocks ads and basic trackers."
        case .standard: return "Blocks ads, trackers, and malicious domains."
        case .high:     return "Aggressive blocking including telemetry."
        case .family:   return "Standard + adult content filtering."
        }
    }
}

// MARK: - Service categories (Mac copy)

private struct MacServiceEntry {
    let id: String
    let label: String
}

private enum MacServiceCategory: CaseIterable {
    case social, entertainment, gaming, communication, gambling

    var label: String {
        switch self {
        case .social:         return "Social Media"
        case .entertainment:  return "Entertainment"
        case .gaming:         return "Gaming"
        case .communication:  return "Communication"
        case .gambling:       return "Gambling"
        }
    }

    var services: [MacServiceEntry] {
        switch self {
        case .social:
            return [
                .init(id: "youtube",   label: "YouTube"),
                .init(id: "tiktok",    label: "TikTok"),
                .init(id: "instagram", label: "Instagram"),
                .init(id: "facebook",  label: "Facebook"),
                .init(id: "twitter",   label: "X / Twitter"),
                .init(id: "reddit",    label: "Reddit"),
                .init(id: "snapchat",  label: "Snapchat"),
            ]
        case .entertainment:
            return [
                .init(id: "netflix",          label: "Netflix"),
                .init(id: "hulu",             label: "Hulu"),
                .init(id: "amazon_streaming", label: "Prime Video"),
                .init(id: "disney",           label: "Disney+"),
                .init(id: "twitch",           label: "Twitch"),
            ]
        case .gaming:
            return [
                .init(id: "steam",       label: "Steam"),
                .init(id: "battle_net",  label: "Battle.net"),
                .init(id: "xbox",        label: "Xbox"),
                .init(id: "playstation", label: "PlayStation"),
            ]
        case .communication:
            return [.init(id: "discord", label: "Discord")]
        case .gambling:
            return [
                .init(id: "gambling", label: "Gambling (general)"),
                .init(id: "betway",   label: "Betway"),
                .init(id: "betfair",  label: "Betfair"),
            ]
        }
    }
}
