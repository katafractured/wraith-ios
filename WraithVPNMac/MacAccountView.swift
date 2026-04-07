// MacAccountView.swift
// WraithVPNMac
//
// Settings / account management window.
// Covers: subscription status, token entry, VPN peer management, Haven DNS preferences.

import SwiftUI

struct MacAccountView: View {

    @EnvironmentObject var storeKit: StoreKitManager
    @EnvironmentObject var vpn:      WireGuardManager
    @EnvironmentObject var haven:    HavenDNSManager

    @State private var showTokenEntry = false
    @State private var showRevokeAlert = false
    @State private var isRestoring = false

    var body: some View {
        ScrollView {
            VStack(spacing: KFSpacing.md) {
                subscriptionCard
                vpnPeerCard
                havenCard
                authCard
            }
            .padding(KFSpacing.lg)
        }
        .frame(minWidth: 400, minHeight: 460)
        .background(Color.kfBackground)
        .preferredColorScheme(.dark)
        .navigationTitle("Account & Settings")
        .sheet(isPresented: $showTokenEntry) {
            TokenEntryView()
                .environmentObject(storeKit)
        }
        .alert("Revoke VPN Peer", isPresented: $showRevokeAlert) {
            Button("Revoke", role: .destructive) {
                Task { await vpn.revokePeer() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes your VPN configuration and frees the device slot. You can re-provision at any time.")
        }
    }

    // MARK: - Subscription

    private var subscriptionCard: some View {
        VStack(alignment: .leading, spacing: KFSpacing.sm) {
            sectionHeader("Subscription")

            if let sub = storeKit.subscription, !sub.isExpired {
                HStack(spacing: KFSpacing.md) {
                    ZStack {
                        Circle()
                            .fill(Color.kfAccentPurple.opacity(0.15))
                            .frame(width: 44, height: 44)
                        Image(systemName: "shield.lefthalf.filled")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(Color.kfAccentPurple)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(sub.planDisplayName)
                            .font(KFFont.heading(16))
                            .foregroundStyle(.white)
                        Text("Expires \(sub.expiryFormatted)")
                            .font(KFFont.caption(12))
                            .foregroundStyle(Color.kfTextMuted)
                    }
                    Spacer()
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(Color.kfConnected)
                        .font(.system(size: 18))
                }
            } else {
                HStack {
                    Text("No active subscription")
                        .font(KFFont.body(14))
                        .foregroundStyle(Color.kfTextMuted)
                    Spacer()
                    Button("Activate") { showTokenEntry = true }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.kfAccentBlue)
                        .controlSize(.small)
                }
            }
        }
        .padding(KFSpacing.md)
        .kfCard()
    }

    // MARK: - VPN Peer

    private var vpnPeerCard: some View {
        VStack(alignment: .leading, spacing: KFSpacing.sm) {
            sectionHeader("VPN")

            HStack(spacing: KFSpacing.md) {
                ZStack {
                    Circle()
                        .fill(Color.kfAccentBlue.opacity(0.12))
                        .frame(width: 36, height: 36)
                    Image(systemName: vpn.isProvisioned ? "network" : "network.slash")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(vpn.isProvisioned ? Color.kfAccentBlue : Color.kfTextMuted)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(vpn.isProvisioned ? "Peer provisioned" : "No peer")
                        .font(KFFont.body(13))
                        .foregroundStyle(.white)
                    if let ip = vpn.assignedIP {
                        Text(ip)
                            .font(KFFont.mono(11))
                            .foregroundStyle(Color.kfTextMuted)
                    }
                }
                Spacer()
                if vpn.isProvisioned {
                    Button("Revoke") { showRevokeAlert = true }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .foregroundStyle(Color.kfError)
                }
            }

            if !simpleMode {
                Divider().background(Color.kfBorder)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Kill Switch")
                            .font(KFFont.body(13))
                            .foregroundStyle(.white)
                        Text("Block all traffic if tunnel drops")
                            .font(KFFont.caption(11))
                            .foregroundStyle(Color.kfTextMuted)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { vpn.tunnelMode == .full },
                        set: { on in Task { await vpn.setTunnelMode(on ? .full : .standard) } }
                    ))
                    .toggleStyle(.switch)
                    .tint(Color.kfAccentPurple)
                }
            }
        }
        .padding(KFSpacing.md)
        .kfCard()
    }

    // MARK: - Haven DNS

    private var havenCard: some View {
        VStack(alignment: .leading, spacing: KFSpacing.sm) {
            sectionHeader("Haven DNS")

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(haven.isEnabled ? "Protection Active" : "Protection Off")
                        .font(KFFont.body(13))
                        .foregroundStyle(.white)
                    Text("Ad & tracker blocking via WraithGate nodes")
                        .font(KFFont.caption(11))
                        .foregroundStyle(Color.kfTextMuted)
                }
                Spacer()
                if haven.isLoading {
                    ProgressView().scaleEffect(0.7)
                } else {
                    Toggle("", isOn: Binding(
                        get: { haven.isEnabled },
                        set: { _ in Task { await haven.toggle() } }
                    ))
                    .toggleStyle(.switch)
                    .tint(Color.kfConnected)
                }
            }

            if let err = haven.error {
                Text(err)
                    .font(KFFont.caption(11))
                    .foregroundStyle(Color.kfError)
            }
        }
        .padding(KFSpacing.md)
        .kfCard()
    }

    // MARK: - Auth

    private var authCard: some View {
        VStack(alignment: .leading, spacing: KFSpacing.sm) {
            sectionHeader("Account")

            VStack(spacing: KFSpacing.xs) {
                macActionRow(
                    icon: "key.fill",
                    title: "Enter / Change Token",
                    subtitle: "Link a Stripe or portal purchase"
                ) {
                    showTokenEntry = true
                }

                Divider().background(Color.kfBorder)

                macActionRow(
                    icon: "arrow.clockwise",
                    title: "Restore App Store Purchase",
                    subtitle: "Sync your iOS subscription to this Mac"
                ) {
                    isRestoring = true
                    Task {
                        await storeKit.restorePurchases()
                        isRestoring = false
                    }
                }

                if isRestoring {
                    HStack {
                        Spacer()
                        ProgressView("Restoring…")
                            .scaleEffect(0.8)
                        Spacer()
                    }
                }

                Divider().background(Color.kfBorder)

                macActionRow(
                    icon: "arrow.right.square",
                    title: "Sign Out",
                    subtitle: "Remove token from this device",
                    destructive: true
                ) {
                    storeKit.signOut()
                }
            }
        }
        .padding(KFSpacing.md)
        .kfCard()
    }

    // MARK: - Helpers

    @AppStorage("simpleMode") private var simpleMode = true

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(KFFont.caption(10, weight: .bold))
            .kerning(1.5)
            .foregroundStyle(Color.kfTextMuted)
    }

    private func macActionRow(
        icon: String,
        title: String,
        subtitle: String,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: KFSpacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(destructive ? Color.kfError : Color.kfAccentBlue)
                    .frame(width: 28, height: 28)
                    .background((destructive ? Color.kfError : Color.kfAccentBlue).opacity(0.12))
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(KFFont.body(13))
                        .foregroundStyle(destructive ? Color.kfError : .white)
                    Text(subtitle)
                        .font(KFFont.caption(11))
                        .foregroundStyle(Color.kfTextMuted)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.kfTextMuted)
            }
        }
        .buttonStyle(.plain)
    }
}
