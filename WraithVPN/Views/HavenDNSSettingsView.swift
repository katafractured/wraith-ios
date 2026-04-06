// HavenDNSSettingsView.swift
// WraithVPN
//
// Per-user AdGuard filter settings: protection level, safe browsing,
// family filter, and per-service blocking. Pro/founder features are
// gated — free users see a locked state with an upgrade prompt.

import SwiftUI

struct HavenDNSSettingsView: View {

    @EnvironmentObject var haven:    HavenDNSManager
    @EnvironmentObject var storeKit: StoreKitManager
    @Environment(\.dismiss) private var dismiss

    // MARK: - Body

    var body: some View {
        ZStack {
            Color.kfBackground.ignoresSafeArea()

            Group {
                if let prefs = haven.preferences {
                    content(prefs)
                } else if haven.loadPreferencesError {
                    errorState
                } else {
                    loadingState
                }
            }
        }
        .navigationTitle("Haven DNS Filters")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.kfBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .preferredColorScheme(.dark)
        .task { await haven.loadPreferences() }
    }

    // MARK: - Main content

    private func content(_ prefs: DnsPreferences) -> some View {
        ScrollView {
            VStack(spacing: KFSpacing.lg) {
                tierBanner(prefs)
                protectionLevelCard(prefs)
                advancedCard(prefs)
                blockedServicesCard(prefs)
            }
            .padding(KFSpacing.md)
        }
    }

    // MARK: - Tier banner

    private func tierBanner(_ prefs: DnsPreferences) -> some View {
        HStack(spacing: KFSpacing.sm) {
            Image(systemName: prefs.isPro ? "shield.fill" : "shield")
                .font(.system(size: 18))
                .foregroundStyle(prefs.isPro ? Color.kfAccentBlue : Color.kfTextMuted)

            VStack(alignment: .leading, spacing: 2) {
                Text(tierLabel(prefs.tier))
                    .font(KFFont.heading(15))
                    .foregroundStyle(.white)
                Text(prefs.isPro
                     ? "All filters available on your plan."
                     : "Upgrade to Haven Pro for advanced filtering.")
                    .font(KFFont.caption(12))
                    .foregroundStyle(Color.kfTextSecondary)
            }

            Spacer()

            if !prefs.isPro {
                NavigationLink("Upgrade") {
                    PaywallView().environmentObject(storeKit)
                }
                .font(KFFont.body(13))
                .foregroundStyle(Color.kfAccentBlue)
            }
        }
        .padding(KFSpacing.md)
        .kfCard()
    }

    // MARK: - Protection level

    private func protectionLevelCard(_ prefs: DnsPreferences) -> some View {
        VStack(alignment: .leading, spacing: KFSpacing.md) {
            sectionHeader("Protection Level")
            Text("Controls which domains are blocked. Higher levels filter more aggressively.")
                .font(KFFont.caption(12))
                .foregroundStyle(Color.kfTextMuted)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: KFSpacing.xs) {
                ForEach(ProtectionLevel.allCases, id: \.self) { level in
                    protectionLevelRow(level, prefs: prefs)
                }
            }
        }
        .padding(KFSpacing.md)
        .kfCard()
    }

    private func protectionLevelRow(_ level: ProtectionLevel, prefs: DnsPreferences) -> some View {
        let available = prefs.protectionLevels.contains(level.rawValue)
        let selected  = prefs.protectionLevel == level.rawValue
        return Button {
            guard available else { return }
            save(DnsPreferencesUpdate(protectionLevel: level.rawValue))
        } label: {
            HStack(spacing: KFSpacing.sm) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(selected ? Color.kfAccentBlue : Color.kfTextMuted)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(level.label)
                            .font(KFFont.body(14))
                            .foregroundStyle(available ? Color.white : Color.kfTextMuted)
                        if !available { proTag }
                    }
                    Text(level.description)
                        .font(KFFont.caption(12))
                        .foregroundStyle(Color.kfTextMuted)
                }

                Spacer()

                if !available {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.kfTextMuted)
                }
            }
            .padding(KFSpacing.sm)
            .background(
                RoundedRectangle(cornerRadius: KFRadius.md, style: .continuous)
                    .fill(selected ? Color.kfAccentBlue.opacity(0.1) : Color.kfSurfaceElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: KFRadius.md, style: .continuous)
                    .strokeBorder(selected ? Color.kfAccentBlue.opacity(0.4) : Color.clear, lineWidth: 1)
            )
        }
        .disabled(!available || haven.isUpdatingPreferences)
    }

    // MARK: - Advanced toggles (safe browsing + family filter)

    private func advancedCard(_ prefs: DnsPreferences) -> some View {
        VStack(alignment: .leading, spacing: KFSpacing.md) {
            sectionHeader("Advanced Filtering")

            advancedToggle(
                icon: "eye.slash.fill",
                label: "Safe Browsing",
                description: "Blocks known malware, phishing, and deceptive sites.",
                isOn: prefs.safeBrowsing,
                locked: !prefs.isPro
            ) { enabled in
                save(DnsPreferencesUpdate(safeBrowsing: enabled))
            }

            Divider().background(Color.kfBorder)

            advancedToggle(
                icon: "figure.2.and.child.holdinghands",
                label: "Family Filter",
                description: "Blocks adult content across all devices on this connection.",
                isOn: prefs.familyFilter,
                locked: !prefs.isPro
            ) { enabled in
                save(DnsPreferencesUpdate(familyFilter: enabled))
            }
        }
        .padding(KFSpacing.md)
        .kfCard()
    }

    private func advancedToggle(
        icon: String,
        label: String,
        description: String,
        isOn: Bool,
        locked: Bool,
        onToggle: @escaping (Bool) -> Void
    ) -> some View {
        HStack(spacing: KFSpacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(locked ? Color.kfTextMuted : Color.kfAccentBlue)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(label)
                        .font(KFFont.body(14))
                        .foregroundStyle(locked ? Color.kfTextMuted : .white)
                    if locked { proTag }
                }
                Text(description)
                    .font(KFFont.caption(12))
                    .foregroundStyle(Color.kfTextMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            if locked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.kfTextMuted)
            } else {
                Toggle("", isOn: Binding(
                    get: { isOn },
                    set: { onToggle($0) }
                ))
                .labelsHidden()
                .tint(Color.kfAccentBlue)
                .disabled(haven.isUpdatingPreferences)
            }
        }
    }

    // MARK: - Blocked services

    private func blockedServicesCard(_ prefs: DnsPreferences) -> some View {
        VStack(alignment: .leading, spacing: KFSpacing.md) {
            HStack {
                sectionHeader("Block Services")
                Spacer()
                if !prefs.isPro { proTag }
            }

            if prefs.isPro {
                ForEach(ServiceCategory.allCases, id: \.label) { category in
                    let services = category.services.filter { prefs.blockableServices.contains($0.id) }
                    if !services.isEmpty {
                        serviceCategory(label: category.label, services: services, prefs: prefs)
                    }
                }
            } else {
                Text("Block specific services like YouTube, TikTok, or gambling sites. Available with Haven Pro.")
                    .font(KFFont.caption(13))
                    .foregroundStyle(Color.kfTextMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(KFSpacing.md)
        .kfCard()
    }

    private func serviceCategory(label: String, services: [ServiceEntry], prefs: DnsPreferences) -> some View {
        VStack(alignment: .leading, spacing: KFSpacing.xs) {
            Text(label.uppercased())
                .font(KFFont.caption(10, weight: .bold))
                .kerning(1.2)
                .foregroundStyle(Color.kfTextMuted)
                .padding(.top, KFSpacing.xs)

            ForEach(services, id: \.id) { service in
                let isBlocked = prefs.blockedServices.contains(service.id)
                Button {
                    var updated = prefs.blockedServices
                    if isBlocked { updated.removeAll { $0 == service.id } }
                    else { updated.append(service.id) }
                    save(DnsPreferencesUpdate(blockedServices: updated))
                } label: {
                    HStack(spacing: KFSpacing.sm) {
                        Text(service.emoji)
                            .font(.system(size: 18))
                            .frame(width: 28)
                        Text(service.label)
                            .font(KFFont.body(14))
                            .foregroundStyle(.white)
                        Spacer()
                        Image(systemName: isBlocked ? "checkmark.square.fill" : "square")
                            .font(.system(size: 18))
                            .foregroundStyle(isBlocked ? Color.kfError : Color.kfTextMuted)
                    }
                    .padding(.vertical, 6)
                }
                .disabled(haven.isUpdatingPreferences)
            }
        }
    }

    // MARK: - Loading / error states

    private var loadingState: some View {
        VStack(spacing: KFSpacing.lg) {
            ProgressView()
                .tint(Color.kfAccentBlue)
                .scaleEffect(1.3)
            Text("Loading settings…")
                .font(KFFont.body())
                .foregroundStyle(Color.kfTextMuted)
        }
    }

    private var errorState: some View {
        VStack(spacing: KFSpacing.lg) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 36))
                .foregroundStyle(Color.kfTextMuted)
            Text("Couldn't load settings")
                .font(KFFont.heading(16))
                .foregroundStyle(.white)
            Text("Check your connection and try again.")
                .font(KFFont.caption(13))
                .foregroundStyle(Color.kfTextMuted)
            Button("Retry") {
                Task { await haven.loadPreferences() }
            }
            .font(KFFont.body(14))
            .foregroundStyle(Color.kfAccentBlue)
        }
        .multilineTextAlignment(.center)
        .padding(KFSpacing.xl)
    }

    // MARK: - Helpers

    private var proTag: some View {
        Text("PRO")
            .font(KFFont.caption(9, weight: .bold))
            .kerning(0.8)
            .foregroundStyle(Color.kfAccentBlue)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.kfAccentBlue.opacity(0.15))
            .clipShape(Capsule())
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(KFFont.caption(11, weight: .bold))
            .kerning(1.5)
            .foregroundStyle(Color.kfTextMuted)
    }

    private func tierLabel(_ tier: String) -> String {
        switch tier {
        case "founder": return "Founder"
        case "pro":     return "Haven Pro"
        default:        return "Haven Free"
        }
    }

    private func save(_ update: DnsPreferencesUpdate) {
        Task { try? await haven.updatePreferences(update) }
    }
}

// MARK: - Protection level enum

private enum ProtectionLevel: String, CaseIterable {
    case none     = "NONE"
    case low      = "LOW"
    case standard = "STANDARD"
    case high     = "HIGH"
    case family   = "FAMILY"

    var label: String {
        switch self {
        case .none:     return "None"
        case .low:      return "Low"
        case .standard: return "Standard"
        case .high:     return "High"
        case .family:   return "Family"
        }
    }

    var description: String {
        switch self {
        case .none:     return "No filtering — all DNS requests pass through."
        case .low:      return "Blocks ads and basic trackers."
        case .standard: return "Blocks ads, trackers, and malicious domains."
        case .high:     return "Aggressive blocking including telemetry."
        case .family:   return "Standard + adult content filtering."
        }
    }
}

// MARK: - Service categories

private struct ServiceEntry {
    let id: String
    let label: String
    let emoji: String
}

private enum ServiceCategory: CaseIterable {
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

    var services: [ServiceEntry] {
        switch self {
        case .social:
            return [
                .init(id: "youtube",   label: "YouTube",   emoji: "▶️"),
                .init(id: "tiktok",    label: "TikTok",    emoji: "🎵"),
                .init(id: "instagram", label: "Instagram", emoji: "📸"),
                .init(id: "facebook",  label: "Facebook",  emoji: "👥"),
                .init(id: "twitter",   label: "X / Twitter", emoji: "🐦"),
                .init(id: "reddit",    label: "Reddit",    emoji: "🤖"),
                .init(id: "snapchat",  label: "Snapchat",  emoji: "👻"),
                .init(id: "pinterest", label: "Pinterest", emoji: "📌"),
                .init(id: "tumblr",    label: "Tumblr",    emoji: "📝"),
                .init(id: "vk",        label: "VK",        emoji: "💬"),
                .init(id: "9gag",      label: "9GAG",      emoji: "😂"),
                .init(id: "4chan",     label: "4chan",      emoji: "🔴"),
            ]
        case .entertainment:
            return [
                .init(id: "netflix",          label: "Netflix",        emoji: "🎬"),
                .init(id: "hulu",             label: "Hulu",           emoji: "📺"),
                .init(id: "amazon_streaming", label: "Prime Video",    emoji: "🛒"),
                .init(id: "disney",           label: "Disney+",        emoji: "🏰"),
                .init(id: "apple_streaming",  label: "Apple TV+",      emoji: "🍎"),
                .init(id: "twitch",           label: "Twitch",         emoji: "🎮"),
            ]
        case .gaming:
            return [
                .init(id: "steam",       label: "Steam",       emoji: "🕹️"),
                .init(id: "battle_net",  label: "Battle.net",  emoji: "⚔️"),
                .init(id: "xbox",        label: "Xbox",        emoji: "🟢"),
                .init(id: "playstation", label: "PlayStation", emoji: "🎮"),
            ]
        case .communication:
            return [
                .init(id: "discord", label: "Discord", emoji: "💬"),
            ]
        case .gambling:
            return [
                .init(id: "gambling", label: "Gambling (general)", emoji: "🎲"),
                .init(id: "betway",   label: "Betway",             emoji: "🃏"),
                .init(id: "betfair",  label: "Betfair",            emoji: "🏇"),
            ]
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        HavenDNSSettingsView()
            .environmentObject(HavenDNSManager())
            .environmentObject(StoreKitManager())
    }
}
