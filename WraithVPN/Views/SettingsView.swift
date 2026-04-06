// SettingsView.swift
// WraithVPN
//
// Account & settings screen: plan info, expiry, manage subscription link,
// sign-out, regenerate keypair option, and app version.

import SwiftUI
import StoreKit

struct SettingsView: View {

    @EnvironmentObject var storeKit: StoreKitManager
    @EnvironmentObject var vpn:      WireGuardManager
    @EnvironmentObject var haven:    HavenDNSManager
    @AppStorage("hasUnlockedFreeTier") private var hasUnlockedFreeTier = false

    @State private var showSignOutAlert    = false
    @State private var showRevokeAlert     = false
    @State private var showRegenerateAlert = false
    @State private var isRestoring         = false
    @State private var showTokenEntry      = false

    // MARK: - Body

    var body: some View {
        ZStack {
            Color.kfBackground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: KFSpacing.lg) {
                    overviewCard
                    accountCard
                    havenDNSCard
                    connectionCard
                    subscriptionCard
                    supportCard
                    dangerCard
                    versionFooter
                }
                .padding(KFSpacing.md)
            }
        }
        .navigationTitle("Account & Settings")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(Color.kfBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .preferredColorScheme(.dark)
        .alert("Sign Out", isPresented: $showSignOutAlert) {
            Button("Sign Out", role: .destructive) { storeKit.signOut() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your subscription token will be removed from this device. To sign in again, use the same method you originally purchased through — Restore Purchase for App Store, or enter your token if you purchased via another gateway.")
        }
        .alert("Reset VPN Configuration", isPresented: $showRevokeAlert) {
            Button("Reset", role: .destructive) {
                Task { await vpn.revokePeer() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will disconnect the VPN and remove your current WireGuard configuration from the server. A new configuration will be created the next time you connect.")
        }
        .alert("Regenerate Keys", isPresented: $showRegenerateAlert) {
            Button("Regenerate", role: .destructive) { regenerateKeys() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your existing WireGuard keypair will be replaced. You will need to reconnect afterwards. This is useful if you believe your private key has been compromised.")
        }
    }

    // MARK: - Account card

    private var overviewCard: some View {
        VStack(alignment: .leading, spacing: KFSpacing.md) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("WRAITHVPN")
                        .font(KFFont.caption(11, weight: .bold))
                        .kerning(1.5)
                        .foregroundStyle(Color.kfTextMuted)
                    Text("Account Overview")
                        .font(KFFont.heading(24))
                        .foregroundStyle(.white)
                    Text("Manage your subscription, route status, and recovery actions from one place.")
                        .font(KFFont.body(14))
                        .foregroundStyle(Color.kfTextSecondary)
                }
                Spacer()
                Image(systemName: "person.text.rectangle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(LinearGradient.kfAccent)
                    .frame(width: 48, height: 48)
                    .background(Color.kfSurfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: KFRadius.md, style: .continuous))
            }

            HStack(spacing: KFSpacing.sm) {
                overviewPill(
                    title: "Plan",
                    value: planLabel,
                    tint: storeKit.subscription == nil && !hasUnlockedFreeTier ? Color.kfTextMuted : Color.kfAccentBlue
                )
                overviewPill(
                    title: "VPN",
                    value: vpn.status.label,
                    tint: vpn.status.swiftUIColor
                )
            }
        }
        .padding(KFSpacing.md)
        .kfCard()
    }

    private func overviewPill(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(KFFont.caption(10, weight: .bold))
                .kerning(1.2)
                .foregroundStyle(Color.kfTextMuted)
            Text(value)
                .font(KFFont.body(14))
                .foregroundStyle(.white)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(KFSpacing.sm)
        .background(tint.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: KFRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: KFRadius.md, style: .continuous)
                .stroke(tint.opacity(0.22), lineWidth: 1)
        )
    }

    private var accountCard: some View {
        VStack(alignment: .leading, spacing: KFSpacing.md) {
            sectionHeader("Subscription")

            if let sub = storeKit.subscription {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(sub.planDisplayName)
                            .font(KFFont.heading(16))
                            .foregroundStyle(.white)
                        Text("Expires \(sub.expiryFormatted)")
                            .font(KFFont.caption())
                            .foregroundStyle(sub.isExpired ? Color.kfError : Color.kfTextMuted)
                    }
                    Spacer()
                    if sub.isExpired {
                        Label("Expired", systemImage: "exclamationmark.circle.fill")
                            .font(KFFont.caption(12, weight: .semibold))
                            .foregroundStyle(Color.kfError)
                    } else {
                        Label("Active", systemImage: "checkmark.circle.fill")
                            .font(KFFont.caption(12, weight: .semibold))
                            .foregroundStyle(Color.kfConnected)
                    }
                }
            } else if hasUnlockedFreeTier {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Haven DNS Free")
                            .font(KFFont.heading(16))
                            .foregroundStyle(.white)
                        Text("Free protection with upgrade options for full WraithGate access.")
                            .font(KFFont.caption())
                            .foregroundStyle(Color.kfTextMuted)
                    }
                    Spacer()
                    NavigationLink("Upgrade") {
                        PaywallView()
                            .environmentObject(storeKit)
                    }
                    .font(KFFont.body(14))
                    .foregroundStyle(Color.kfAccentBlue)
                }
            } else {
                HStack {
                    Text("No active subscription")
                        .font(KFFont.body())
                        .foregroundStyle(Color.kfTextSecondary)
                    Spacer()
                    NavigationLink("Subscribe") {
                        PaywallView()
                            .environmentObject(storeKit)
                    }
                    .font(KFFont.body(14))
                    .foregroundStyle(Color.kfAccentBlue)
                }
            }
        }
        .padding(KFSpacing.md)
        .kfCard()
    }

    // MARK: - Connection card

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: KFSpacing.md) {
            sectionHeader("Connection")

            SettingsRow(icon: "server.rack", label: "Active Server") {
                Text(vpn.connectedServer?.cityName ?? "None")
                    .font(KFFont.body(14))
                    .foregroundStyle(Color.kfTextMuted)
            }

            Divider().background(Color.kfBorder)

            SettingsRow(icon: "network", label: "Exit IP") {
                Text(vpn.exitIP ?? vpn.assignedIP ?? "—")
                    .font(KFFont.mono(13))
                    .foregroundStyle(Color.kfTextMuted)
            }

            Divider().background(Color.kfBorder)

            SettingsRow(icon: "shield.lefthalf.fill", label: "Status") {
                Text(vpn.status.label)
                    .font(KFFont.body(14))
                    .foregroundStyle(vpn.status.swiftUIColor)
            }

            Divider().background(Color.kfBorder)

            VStack(alignment: .leading, spacing: 4) {
                SettingsRow(icon: "lock.shield.fill", label: "Kill Switch") {
                    Toggle("", isOn: Binding(
                        get: { vpn.tunnelMode == .full },
                        set: { on in Task { await vpn.setTunnelMode(on ? .full : .standard) } }
                    ))
                    .labelsHidden()
                    .tint(Color.kfAccentBlue)
                }
                Text(vpn.tunnelMode == .full
                     ? "Full mode: iOS forces all traffic through the tunnel. If the VPN drops, there is no internet until it reconnects."
                     : "Standard mode: your traffic still routes through the VPN exit, but if the tunnel drops iOS falls back to your normal connection. System apps like Mail and Maps stay functional.")
                    .font(KFFont.caption(11))
                    .foregroundStyle(Color.kfTextMuted)
                    .padding(.leading, 36)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().background(Color.kfBorder)

            if let since = vpn.connectedSince {
                SettingsRow(icon: "timer", label: "Connected For") {
                    Text(since, style: .timer)
                        .font(KFFont.mono(13))
                        .foregroundStyle(Color.kfTextMuted)
                        .monospacedDigit()
                }
                Divider().background(Color.kfBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                SettingsRow(icon: "arrow.trianglehead.2.clockwise.rotate.90", label: "Stay Connected") {
                    Toggle("", isOn: Binding(
                        get: { vpn.autoConnectEnabled },
                        set: { enabled in Task { await vpn.setAutoConnect(enabled) } }
                    ))
                    .labelsHidden()
                    .tint(Color.kfAccentBlue)
                }
                Text("Automatically reconnects when you switch networks or restart your device. Disconnecting manually will pause this until you reconnect.")
                    .font(KFFont.caption(11))
                    .foregroundStyle(Color.kfTextMuted)
                    .padding(.leading, 36)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().background(Color.kfBorder)

            Button {
                showRevokeAlert = true
            } label: {
                SettingsRow(icon: "arrow.counterclockwise", label: "Reset VPN Configuration") {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.kfTextMuted)
                }
            }
        }
        .padding(KFSpacing.md)
        .kfCard()
    }

    // MARK: - Haven DNS card

    private var havenDNSCard: some View {
        VStack(alignment: .leading, spacing: KFSpacing.md) {
            sectionHeader("Haven DNS")

            HStack(spacing: KFSpacing.sm) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 18))
                    .foregroundStyle(haven.isEnabled ? Color.kfConnected : Color.kfTextMuted)
                    .frame(width: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Ad & Tracker Blocking")
                        .font(KFFont.body(15))
                        .foregroundStyle(.white)
                    Text(haven.isEnabled ? "Active — filtering ads and trackers at the DNS level" : "Blocks ads, trackers, and malware at DNS level — works with or without VPN. Free tier included.")
                        .font(KFFont.caption(13))
                        .foregroundStyle(Color.kfTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                if haven.isLoading {
                    ProgressView()
                        .tint(Color.kfAccentBlue)
                } else {
                    Toggle("", isOn: Binding(
                        get: { haven.isEnabled },
                        set: { _ in Task { await haven.toggle() } }
                    ))
                    .labelsHidden()
                    .tint(Color.kfAccentBlue)
                }
            }

            if let err = haven.error {
                Text(err)
                    .font(KFFont.caption(12))
                    .foregroundStyle(Color.kfError)
            }

            if haven.isEnabled {
                Divider().background(Color.kfBorder)

                NavigationLink {
                    HavenDNSSettingsView()
                        .environmentObject(haven)
                        .environmentObject(storeKit)
                } label: {
                    SettingsRow(icon: "slider.horizontal.3", label: "Configure Filters") {
                        HStack(spacing: 4) {
                            if let prefs = haven.preferences {
                                Text(prefs.protectionLevel.capitalized)
                                    .font(KFFont.caption(12))
                                    .foregroundStyle(Color.kfTextMuted)
                            }
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.kfTextMuted)
                        }
                    }
                }
            }
        }
        .padding(KFSpacing.md)
        .kfCard()
        .task {
            await haven.refreshStatus()
            await haven.loadPreferences()
        }
    }

    // MARK: - Subscription management card

    private var subscriptionCard: some View {
        VStack(alignment: .leading, spacing: KFSpacing.md) {
            sectionHeader("Manage")

            Link(destination: URL(string: "https://apps.apple.com/account/subscriptions")!) {
                SettingsRow(icon: "creditcard", label: "Manage Subscription") {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.kfAccentBlue)
                }
            }

            Divider().background(Color.kfBorder)

            Button {
                isRestoring = true
                Task {
                    await storeKit.restorePurchases()
                    isRestoring = false
                }
            } label: {
                SettingsRow(icon: "arrow.clockwise", label: "Restore Purchase") {
                    if isRestoring {
                        ProgressView().tint(Color.kfAccentBlue)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.kfTextMuted)
                    }
                }
            }
            .disabled(isRestoring)

            Divider().background(Color.kfBorder)

            Button { showTokenEntry = true } label: {
                SettingsRow(icon: "key.fill", label: "Activate with Token") {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.kfTextMuted)
                }
            }
            .sheet(isPresented: $showTokenEntry) {
                TokenActivationSheet()
                    .environmentObject(storeKit)
            }
        }
        .padding(KFSpacing.md)
        .kfCard()
    }

    // MARK: - Support card

    private var supportCard: some View {
        VStack(alignment: .leading, spacing: KFSpacing.md) {
            sectionHeader("Support")

            HStack(spacing: KFSpacing.sm) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.kfConnected)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Zero-Log Policy")
                        .font(KFFont.body(14))
                        .foregroundStyle(.white)
                    Text("We do not log your traffic, DNS queries, or connection timestamps.")
                        .font(KFFont.caption(12))
                        .foregroundStyle(Color.kfTextMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider().background(Color.kfBorder)

            HStack(spacing: KFSpacing.sm) {
                Image(systemName: "key.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.kfAccentBlue)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Access Recovery")
                        .font(KFFont.body(14))
                        .foregroundStyle(.white)
                    Text("Keep access to your purchase gateway — App Store or token source. Recovery comes from where you bought, not from us.")
                        .font(KFFont.caption(12))
                        .foregroundStyle(Color.kfTextMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider().background(Color.kfBorder)

            Link(destination: URL(string: "https://katafract.com/privacy/wraith")!) {
                SettingsRow(icon: "hand.raised.fill", label: "Privacy Policy") {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.kfAccentBlue)
                }
            }

            Divider().background(Color.kfBorder)

            Link(destination: URL(string: "https://katafract.com/terms/wraith")!) {
                SettingsRow(icon: "doc.text.fill", label: "Terms of Service") {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.kfAccentBlue)
                }
            }

            Divider().background(Color.kfBorder)

            Link(destination: URL(string: "mailto:support@katafract.com")!) {
                SettingsRow(icon: "envelope.fill", label: "Contact Support") {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.kfAccentBlue)
                }
            }
        }
        .padding(KFSpacing.md)
        .kfCard()
    }

    // MARK: - Danger zone

    private var dangerCard: some View {
        VStack(alignment: .leading, spacing: KFSpacing.md) {
            sectionHeader("Security")

            Button { showRegenerateAlert = true } label: {
                SettingsRow(icon: "key.fill", label: "Regenerate WireGuard Keys") {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.kfTextMuted)
                }
            }

            Divider().background(Color.kfBorder)

            Button { showSignOutAlert = true } label: {
                SettingsRow(icon: "rectangle.portrait.and.arrow.right", label: "Sign Out") {
                    EmptyView()
                }
                .foregroundStyle(Color.kfError)
            }
        }
        .padding(KFSpacing.md)
        .kfCard()
    }

    private var versionFooter: some View {
        VStack(spacing: 4) {
            Text("WraithVPN")
                .font(KFFont.caption(12, weight: .semibold))
                .foregroundStyle(Color.kfTextMuted)
            Text("Version \(appVersion) (\(buildNumber))")
                .font(KFFont.caption(11))
                .foregroundStyle(Color.kfTextMuted.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, KFSpacing.lg)
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(KFFont.caption(11, weight: .bold))
            .kerning(1.5)
            .foregroundStyle(Color.kfTextMuted)
    }

    private func regenerateKeys() {
        Task {
            vpn.disconnect()
            _ = try? vpn.generateKeypair()
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    private var planLabel: String {
        if let subscription = storeKit.subscription {
            return subscription.planDisplayName
        }
        return hasUnlockedFreeTier ? "Haven DNS Free" : "Inactive"
    }
}

// MARK: - Settings row

struct SettingsRow<Trailing: View>: View {
    let icon: String
    let label: String
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: KFSpacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .frame(width: 20)
                .foregroundStyle(Color.kfAccentBlue)

            Text(label)
                .font(KFFont.body(15))
                .foregroundStyle(Color.kfTextPrimary)

            Spacer()

            trailing()
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        SettingsView()
            .environmentObject(StoreKitManager())
            .environmentObject(WireGuardManager())
            .environmentObject(HavenDNSManager())
    }
}
