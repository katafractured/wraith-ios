// MacAccountView.swift
// WraithVPNMac
//
// Settings / account management window — full feature parity with iOS SettingsView.

import SwiftUI
import KatafractStyle

struct MacAccountView: View {

    @EnvironmentObject var storeKit: StoreKitManager
    @EnvironmentObject var vpn:      WireGuardManager
    @EnvironmentObject var haven:    HavenDNSManager

    @State private var showRevokeAlert     = false
    @State private var showSignOutAlert    = false
    @State private var showRegenerateAlert = false
    @State private var isRestoring         = false

    // Peers
    @State private var peerList: PeerListResponse? = nil
    @State private var isPeerListLoading = false
    @State private var peerListError: String? = nil
    @State private var revokingPeerIds: Set<String> = []

    // Security
    @State private var showIdentityLink   = false
    @State private var identityLinkEmail  = ""
    @State private var isLinkingIdentity  = false
    @State private var identityLinked     = UserDefaults.standard.bool(forKey: "identityLinked")
    @State private var identityLinkError: String? = nil

    // Haven sheets
    @State private var showHavenSettings  = false
    @State private var showDnsStats       = false
    @State private var showAchievements   = false

    // Platform status
    @State private var platformStatus: PlatformStatus? = nil

    @AppStorage("simpleMode") private var simpleMode = true

    var body: some View {
        ScrollView {
            VStack(spacing: KFSpacing.md) {
                subscriptionCard
                deviceManagementCard
                securityCard
                havenInsightsCard
                subscriptionManageCard
                supportCard
                versionFooter
            }
            .padding(KFSpacing.lg)
        }
        .frame(minWidth: 440, minHeight: 560)
        .background(Color.kfBackground)
        .preferredColorScheme(.dark)
        .navigationTitle("Account & Settings")
        .sheet(isPresented: $showIdentityLink) {
            identityLinkSheet
        }
        .sheet(isPresented: $showHavenSettings) {
            MacHavenDNSSettingsView()
                .environmentObject(haven)
                .environmentObject(storeKit)
        }
        .sheet(isPresented: $showDnsStats) {
            MacDnsStatsView()
        }
        .sheet(isPresented: $showAchievements) {
            MacAchievementsView()
        }
        .alert("Revoke VPN Peer", isPresented: $showRevokeAlert) {
            Button("Revoke", role: .destructive) { Task { await vpn.revokePeer() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes your VPN configuration and frees the device slot. You can re-provision at any time.")
        }
        .alert("Sign Out", isPresented: $showSignOutAlert) {
            Button("Sign Out", role: .destructive) {
                Task {
                    await vpn.revokePeer()
                    storeKit.signOut()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your subscription token will be removed from this device.")
        }
        .alert("Regenerate Keys?", isPresented: $showRegenerateAlert) {
            Button("Regenerate", role: .destructive) {
                Task {
                    await vpn.revokePeer()
                    _ = try? vpn.generateKeypair()
                    await vpn.autoProvisionIfNeeded()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A new WireGuard keypair will be generated. Your current tunnel will disconnect.")
        }
        .task {
            await loadPeers()
            platformStatus = try? await APIClient.shared.fetchPlatformStatus()
        }
    }

    // MARK: - Subscription card

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
                Text("No active subscription")
                    .font(KFFont.body(14))
                    .foregroundStyle(Color.kfTextMuted)
            }
        }
        .padding(KFSpacing.md)
        .kfCard()
    }

    // MARK: - Device Management

    private var deviceManagementCard: some View {
        VStack(alignment: .leading, spacing: KFSpacing.sm) {
            sectionHeader("Device Management")

            if isPeerListLoading {
                HStack { Spacer(); KataProgressRing(size: 22); Spacer() }
            } else if let err = peerListError {
                Text(err).font(KFFont.caption(12)).foregroundStyle(Color.kfError)
            } else if let pl = peerList {
                // Slots usage
                HStack {
                    Text("\(pl.used) of \(pl.limit) device slots used")
                        .font(KFFont.caption(12))
                        .foregroundStyle(Color.kfTextMuted)
                    Spacer()
                    if !pl.canAdd {
                        Button("Add 5 Slots") {
                            Task { await storeKit.purchaseSeatPack() }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(Color.kfAccentBlue)
                    }
                }

                // Peer list
                ForEach(pl.peers) { peer in
                    Divider().background(Color.kfBorder)
                    HStack(spacing: KFSpacing.sm) {
                        Image(systemName: "laptopcomputer")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.kfAccentBlue)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(peer.label)
                                    .font(KFFont.body(13))
                                    .foregroundStyle(.white)
                                if vpn.activePeerId == peer.peerId {
                                    Text("CURRENT")
                                        .font(KFFont.caption(9, weight: .bold))
                                        .kerning(1)
                                        .foregroundStyle(Color.kfConnected)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(Color.kfConnected.opacity(0.15))
                                        .clipShape(Capsule())
                                }
                            }
                            Text(peer.assignedIpv4)
                                .font(KFFont.mono(10))
                                .foregroundStyle(Color.kfTextMuted)
                        }
                        Spacer()
                        if revokingPeerIds.contains(peer.peerId) {
                            KataProgressRing(size: 20)
                        } else {
                            Button {
                                Task { await revokePeer(peer) }
                            } label: {
                                Image(systemName: "xmark.circle")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Color.kfError)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(KFSpacing.md)
        .kfCard()
    }

    // MARK: - Security

    private var securityCard: some View {
        VStack(alignment: .leading, spacing: KFSpacing.sm) {
            sectionHeader("Security")

            macActionRow(
                icon: "key.fill",
                title: "Regenerate WireGuard Keys",
                subtitle: "Creates a new keypair and re-provisions tunnel"
            ) {
                showRegenerateAlert = true
            }

            Divider().background(Color.kfBorder)

            if identityLinked {
                HStack(spacing: KFSpacing.sm) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.kfConnected)
                        .frame(width: 28, height: 28)
                        .background(Color.kfConnected.opacity(0.12))
                        .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Identity Linked")
                            .font(KFFont.body(13))
                            .foregroundStyle(.white)
                        Text("Recovery email is set")
                            .font(KFFont.caption(11))
                            .foregroundStyle(Color.kfTextMuted)
                    }
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.kfConnected)
                }
            } else {
                macActionRow(
                    icon: "envelope.badge.shield.half.filled",
                    title: "Link Recovery Identity",
                    subtitle: "Set a recovery email for account access"
                ) {
                    showIdentityLink = true
                }
            }

            if let err = identityLinkError {
                Text(err).font(KFFont.caption(11)).foregroundStyle(Color.kfError)
            }
        }
        .padding(KFSpacing.md)
        .kfCard()
    }

    // MARK: - Haven & Stats

    private var havenInsightsCard: some View {
        VStack(alignment: .leading, spacing: KFSpacing.sm) {
            sectionHeader("Haven & Stats")

            macActionRow(
                icon: "slider.horizontal.3",
                title: "Configure DNS Filters",
                subtitle: storeKit.hasDNSSettings ? "Manage protection level & blocked services" : "Haven Pro feature"
            ) {
                guard storeKit.hasDNSSettings else { return }
                showHavenSettings = true
            }

            Divider().background(Color.kfBorder)

            macActionRow(
                icon: "chart.bar.fill",
                title: "DNS Stats",
                subtitle: "View your 30-day blocking history"
            ) {
                showDnsStats = true
            }

            Divider().background(Color.kfBorder)

            macActionRow(
                icon: "trophy.fill",
                title: "Achievements",
                subtitle: "Your privacy milestones"
            ) {
                showAchievements = true
            }
        }
        .padding(KFSpacing.md)
        .kfCard()
    }

    // MARK: - Subscription management

    private var subscriptionManageCard: some View {
        VStack(alignment: .leading, spacing: KFSpacing.sm) {
            sectionHeader("Account")

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
                    HStack(spacing: 8) { KataProgressRing(size: 22); Text("Restoring…").font(.kataBody(14)) }
                    Spacer()
                }
            }

            Divider().background(Color.kfBorder)

            macActionRow(
                icon: "creditcard",
                title: "Manage Subscription",
                subtitle: "App Store subscriptions page"
            ) {
                if let url = URL(string: "https://apps.apple.com/account/subscriptions") {
                    NSWorkspace.shared.open(url)
                }
            }

            Divider().background(Color.kfBorder)

            macActionRow(
                icon: "arrow.right.square",
                title: "Sign Out",
                subtitle: "Remove token from this device",
                destructive: true
            ) {
                showSignOutAlert = true
            }
        }
        .padding(KFSpacing.md)
        .kfCard()
    }

    // MARK: - Support

    private var supportCard: some View {
        VStack(alignment: .leading, spacing: KFSpacing.sm) {
            sectionHeader("Support")

            if let status = platformStatus {
                HStack(spacing: KFSpacing.sm) {
                    Circle()
                        .fill(status.isHealthy ? Color.kfConnected : (status.isDegraded ? Color.orange : Color.kfError))
                        .frame(width: 8, height: 8)
                    Text(status.displayStatus)
                        .font(KFFont.caption(12))
                        .foregroundStyle(Color.kfTextMuted)
                    Spacer()
                }
                .padding(.bottom, KFSpacing.xs)
                Divider().background(Color.kfBorder)
            }

            macActionRow(icon: "hand.raised.fill", title: "Privacy Policy", subtitle: "") {
                if let url = URL(string: "https://katafract.com/privacy") { NSWorkspace.shared.open(url) }
            }
            Divider().background(Color.kfBorder)
            macActionRow(icon: "doc.text", title: "Terms of Service", subtitle: "") {
                if let url = URL(string: "https://katafract.com/terms") { NSWorkspace.shared.open(url) }
            }
            Divider().background(Color.kfBorder)
            macActionRow(icon: "envelope", title: "Contact Support", subtitle: "") {
                if let url = URL(string: "mailto:support@katafract.com") { NSWorkspace.shared.open(url) }
            }
        }
        .padding(KFSpacing.md)
        .kfCard()
    }

    // MARK: - Version footer

    private var versionFooter: some View {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build   = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return Text("WraithVPN \(version) (\(build))")
            .font(KFFont.caption(11))
            .foregroundStyle(Color.kfTextMuted)
            .frame(maxWidth: .infinity)
            .padding(.bottom, KFSpacing.md)
    }

    // MARK: - Identity link sheet

    private var identityLinkSheet: some View {
        VStack(spacing: 16) {
            Text("Link Recovery Identity")
                .font(KFFont.heading(15))
                .foregroundStyle(.white)

            Text("Enter your email address to enable account recovery.")
                .font(KFFont.caption(12))
                .foregroundStyle(Color.kfTextMuted)
                .multilineTextAlignment(.center)

            TextField("you@example.com", text: $identityLinkEmail)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))

            if let err = identityLinkError {
                Text(err).font(.system(size: 11)).foregroundStyle(.red)
            }

            HStack {
                Button("Cancel") { showIdentityLink = false }
                Spacer()
                Button("Link") {
                    Task {
                        isLinkingIdentity = true
                        identityLinkError = nil
                        do {
                            _ = try await APIClient.shared.linkIdentity(type: "email", value: identityLinkEmail)
                            UserDefaults.standard.set(true, forKey: "identityLinked")
                            identityLinked = true
                            showIdentityLink = false
                        } catch {
                            identityLinkError = error.localizedDescription
                        }
                        isLinkingIdentity = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.kfAccentBlue)
                .disabled(identityLinkEmail.isEmpty || isLinkingIdentity)
            }
        }
        .padding(20)
        .frame(minWidth: 320)
        .background(Color.kfBackground)
        .preferredColorScheme(.dark)
    }

    // MARK: - Helpers

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
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(KFFont.caption(11))
                            .foregroundStyle(Color.kfTextMuted)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.kfTextMuted)
            }
        }
        .buttonStyle(.plain)
    }

    private func loadPeers() async {
        isPeerListLoading = true
        peerListError = nil
        do { peerList = try await APIClient.shared.fetchPeers() }
        catch { peerListError = "Could not load devices" }
        isPeerListLoading = false
    }

    private func revokePeer(_ peer: Peer) async {
        revokingPeerIds.insert(peer.peerId)
        defer { revokingPeerIds.remove(peer.peerId) }
        do {
            try await APIClient.shared.deletePeer(peerId: peer.peerId)
            if vpn.activePeerId == peer.peerId { await vpn.revokePeer() }
            await loadPeers()
        } catch {
            peerListError = "Revoke failed: \(error.localizedDescription)"
        }
    }
}

// activePeerId is now a @Published var on WireGuardManager (since 51129ae); extension removed.
