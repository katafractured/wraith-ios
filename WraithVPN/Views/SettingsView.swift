// SettingsView.swift
// WraithVPN
//
// Account & settings screen: plan info, expiry, manage subscription link,
// sign-out, regenerate keypair option, and app version.

import SwiftUI
import KatafractStyle
import StoreKit

struct SettingsView: View {

    @EnvironmentObject var storeKit: StoreKitManager
    @EnvironmentObject var vpn:      WireGuardManager
    @EnvironmentObject var haven:    HavenDNSManager
    @AppStorage("hasUnlockedFreeTier") private var hasUnlockedFreeTier = false
    @AppStorage("simpleMode") private var simpleMode = true


    @State private var showSignOutAlert    = false
    @State private var showRevokeAlert     = false
    @State private var showRegenerateAlert = false
    @State private var isRestoring         = false
    @State private var peerList: PeerListResponse? = nil
    @State private var isPeerListLoading = false
    @State private var peerListError: String? = nil
    @State private var revokingPeerIds: Set<String> = []
    @State private var platformStatus: PlatformStatus? = nil
    @State private var statusCheckDone = false
    @State private var havenPrefsLoaded = false
    @State private var isAdminTokenState: Bool = KeychainHelper.shared.readOptional(for: .tokenIsAdmin) == "1"
    @State private var showIdentityLink = false
    @State private var identityLinkEmail = ""
    @State private var isLinkingIdentity = false
    @State private var identityLinked = UserDefaults.standard.bool(forKey: "identityLinked")
    @State private var identityLinkError: String? = nil
    @State private var showSeatPurchaseError = false
    @State private var tokenVisible  = false
    @State private var tokenCopied   = false

    // MARK: - Body

    var body: some View {
        ZStack {
            Color.kfBackground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: KFSpacing.lg) {
                    overviewCard
                    modeCard
                    accountCard
                    devicesCard
                    havenDNSCard
                    havenInsightsCard
                    if !simpleMode {
                        connectionCard
                    }
                    subscriptionCard
                    tokenCard
                    supportCard
                    if isAdminTokenState {
                        debugCard
                    }
                    diagnosticsCard
                    dangerCard
                    versionFooter
                }
                .padding(KFSpacing.md)
            }
        }
        .task {
            guard !statusCheckDone else { return }
            statusCheckDone = true
            platformStatus = try? await APIClient.shared.fetchPlatformStatus()
            // Silently refresh is_admin flag from API in case it changed since activation
            if let token = try? KeychainHelper.shared.read(for: .subscriptionToken),
               let info = try? await APIClient.shared.validateToken(token) {
                let adminVal = info.isAdmin ? "1" : "0"
                try? KeychainHelper.shared.save(adminVal, for: .tokenIsAdmin)
                isAdminTokenState = info.isAdmin
            }
        }
        .navigationTitle("Account & Settings")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(Color.kfBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .preferredColorScheme(.dark)
        .alert("Sign Out", isPresented: $showSignOutAlert) {
            Button("Sign Out", role: .destructive) {
                Task {
                    await vpn.revokePeer()
                    storeKit.signOut()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your subscription will be removed from this device. To sign in again, use Restore Purchase from the App Store.")
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

    // MARK: - Mode card

    private var modeCard: some View {
        VStack(alignment: .leading, spacing: KFSpacing.sm) {
            HStack(spacing: KFSpacing.md) {
                ZStack {
                    Circle()
                        .fill(simpleMode ? Color.kfAccentBlue.opacity(0.15) : Color.kfAccentPurple.opacity(0.15))
                        .frame(width: 44, height: 44)
                    Image(systemName: simpleMode ? "sparkles" : "slider.horizontal.3")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(simpleMode ? Color.kfAccentBlue : Color.kfAccentPurple)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(simpleMode ? "Simple Mode" : "Advanced Mode")
                            .font(KFFont.heading(16))
                            .foregroundStyle(.white)
                        Text(simpleMode ? "ON" : "ON")
                            .font(KFFont.caption(10, weight: .bold))
                            .kerning(1)
                            .foregroundStyle(simpleMode ? Color.kfAccentBlue : Color.kfAccentPurple)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background((simpleMode ? Color.kfAccentBlue : Color.kfAccentPurple).opacity(0.15))
                            .clipShape(Capsule())
                    }
                    Text(simpleMode
                         ? "DNS protection + nearest VPN. Tap to unlock advanced controls."
                         : "Kill switch, manual server selection, and all connection controls.")
                        .font(KFFont.caption(12))
                        .foregroundStyle(Color.kfTextMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Toggle("", isOn: Binding(
                    get: { !simpleMode },
                    set: { advanced in
                        simpleMode = !advanced
                        if !advanced {
                            // Switching back to simple — disable kill switch + auto-connect.
                            // Stay Connected is advanced-only; enforce it here so the NE
                            // profile doesn't keep isOnDemandEnabled=true in the background.
                            Task {
                                await vpn.setTunnelMode(.standard)
                                await vpn.setAutoConnect(false)
                            }
                        }
                    }
                ))
                .labelsHidden()
                .tint(Color.kfAccentPurple)
            }
        }
        .padding(KFSpacing.md)
        .kfCard()
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

    // MARK: - Devices card

    private var devicesCard: some View {
        VStack(alignment: .leading, spacing: KFSpacing.md) {
            HStack {
                sectionHeader("Devices")
                Spacer()
                if isPeerListLoading {
                    KataProgressRing(size: 22)
                }
            }

            // Haven free users have no token — device management requires a subscription.
            if KeychainHelper.shared.readOptional(for: .subscriptionToken) == nil {
                HStack(spacing: KFSpacing.sm) {
                    Image(systemName: "iphone.slash")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.kfTextMuted)
                        .frame(width: 20)
                    Text("Device management is available with a WraithVPN subscription.")
                        .font(KFFont.body(14))
                        .foregroundStyle(Color.kfTextSecondary)
                }
                NavigationLink("Upgrade to WraithVPN") {
                    PaywallView().environmentObject(storeKit)
                }
                .font(KFFont.body(14))
                .foregroundStyle(Color.kfAccentBlue)
            } else if let list = peerList {
                // Usage bar
                HStack(spacing: KFSpacing.xs) {
                    Text("\(list.used) of \(list.limit) device slots used")
                        .font(KFFont.body(14))
                        .foregroundStyle(.white)
                    Spacer()
                    if !list.canAdd {
                        Text("Limit reached")
                            .font(KFFont.caption(11, weight: .semibold))
                            .foregroundStyle(Color.kfError)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.kfError.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.kfBorder)
                            .frame(height: 6)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(list.canAdd ? Color.kfAccentBlue : Color.kfError)
                            .frame(width: geo.size.width * CGFloat(list.used) / CGFloat(max(list.limit, 1)), height: 6)
                    }
                }
                .frame(height: 6)

                if !list.peers.isEmpty {
                    Divider().background(Color.kfBorder)
                    ForEach(list.peers) { peer in
                        peerRow(peer: peer, isActive: peer.peerId == vpn.activePeerId)
                        if peer.id != list.peers.last?.id {
                            Divider().background(Color.kfBorder)
                        }
                    }
                }

                if !list.canAdd {
                    Divider().background(Color.kfBorder)

                    // Seat pack IAP — available for active subscribers
                    if storeKit.products.contains(where: { $0.id == "com.katafract.wraith.seats.5" }) {
                        Button {
                            Task {
                                await storeKit.purchaseSeatPack()
                                if storeKit.seatPurchaseError != nil {
                                    showSeatPurchaseError = true
                                } else {
                                    await loadPeerList()
                                }
                            }
                        } label: {
                            SettingsRow(icon: "plus.circle.fill", label: "Add 5 Device Slots") {
                                if storeKit.isPurchasingSeatPack {
                                    KataProgressRing()
                                } else {
                                    Text(storeKit.products.first(where: { $0.id == "com.katafract.wraith.seats.5" })?.displayPrice ?? "")
                                        .font(KFFont.caption(12))
                                        .foregroundStyle(Color.kfAccentBlue)
                                }
                            }
                        }
                        .disabled(storeKit.isPurchasingSeatPack)
                        .alert("Purchase Failed", isPresented: $showSeatPurchaseError) {
                            Button("OK", role: .cancel) {}
                        } message: {
                            Text(storeKit.seatPurchaseError ?? "Unknown error")
                        }

                        Divider().background(Color.kfBorder)
                    }

                    NavigationLink {
                        PaywallView().environmentObject(storeKit)
                    } label: {
                        SettingsRow(icon: "arrow.up.circle.fill", label: "Upgrade Plan") {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.kfAccentBlue)
                        }
                    }
                    .foregroundStyle(Color.kfAccentBlue)
                }

            } else if let err = peerListError {
                Text(err)
                    .font(KFFont.caption(12))
                    .foregroundStyle(Color.kfError)
            } else {
                Text("Loading devices…")
                    .font(KFFont.body(14))
                    .foregroundStyle(Color.kfTextMuted)
            }
        }
        .padding(KFSpacing.md)
        .kfCard()
        .task {
            await loadPeerList()
        }
    }

    private func peerRow(peer: Peer, isActive: Bool) -> some View {
        HStack(spacing: KFSpacing.sm) {
            Image(systemName: isActive ? "iphone.radiowaves.left.and.right" : "iphone")
                .font(.system(size: 15))
                .foregroundStyle(isActive ? Color.kfConnected : Color.kfTextMuted)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(peer.label.isEmpty ? "Device" : peer.label)
                        .font(KFFont.body(14))
                        .foregroundStyle(Color.kfTextPrimary)
                    if isActive {
                        Text("This device")
                            .font(KFFont.caption(10, weight: .semibold))
                            .foregroundStyle(Color.kfConnected)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.kfConnected.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }
                Text(peer.nodeId)
                    .font(KFFont.mono(11))
                    .foregroundStyle(Color.kfTextMuted)
            }

            Spacer()

            if !isActive {
                if revokingPeerIds.contains(peer.peerId) {
                    KataProgressRing(size: 20)
                } else {
                    Button {
                        Task { await revokePeer(peer) }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(Color.kfError.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func loadPeerList() async {
        guard KeychainHelper.shared.readOptional(for: .subscriptionToken) != nil else { return }
        isPeerListLoading = true
        peerListError = nil
        defer { isPeerListLoading = false }
        do {
            peerList = try await APIClient.shared.fetchPeers()
        } catch {
            peerListError = "Could not load devices: \(error.localizedDescription)"
        }
    }

    private func revokePeer(_ peer: Peer) async {
        revokingPeerIds.insert(peer.peerId)
        defer { revokingPeerIds.remove(peer.peerId) }
        do {
            try await APIClient.shared.deletePeer(peerId: peer.peerId)
            // If this was the active peer, also clean up the local VPN state
            if peer.peerId == vpn.activePeerId {
                await vpn.revokePeer()
            }
            await loadPeerList()
        } catch {
            peerListError = "Failed to revoke: \(error.localizedDescription)"
        }
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
                     ? "Kill Switch enabled: All traffic is blocked if the VPN disconnects. Your IP address stays hidden, but you'll lose internet until the tunnel reconnects."
                     : "Kill Switch disabled: If the VPN drops, your traffic falls back to your regular connection. You stay connected, but some apps may see your real IP.")
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
                    .foregroundStyle(Color.kfConnected)
                    .frame(width: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Ad & Tracker Blocking")
                        .font(KFFont.body(15))
                        .foregroundStyle(.white)
                    let levelLabel = haven.preferences.map { p in
                        p.protectionLevel == "NONE" ? "Off — no filtering active" : "\(p.protectionLevel.capitalized) protection active"
                    } ?? "Filtering ads, trackers, and malware at DNS level"
                    Text(levelLabel)
                        .font(KFFont.caption(13))
                        .foregroundStyle(Color.kfTextSecondary)
                }

                Spacer()

                if haven.isLoading {
                    KataProgressRing()
                }
            }

            if let err = haven.error {
                Text(err)
                    .font(KFFont.caption(12))
                    .foregroundStyle(Color.kfError)
            }

            Divider().background(Color.kfBorder)

            if storeKit.hasDNSSettings {
                NavigationLink {
                    HavenDNSSettingsView()
                        .environmentObject(haven)
                        .environmentObject(storeKit)
                } label: {
                    SettingsRow(icon: "slider.horizontal.3", label: "Configure Filters") {
                        HStack(spacing: 4) {
                            if let prefs = haven.preferences {
                                Text(prefs.protectionLevel == "NONE" ? "Off" : prefs.protectionLevel.capitalized)
                                    .font(KFFont.caption(12))
                                    .foregroundStyle(prefs.protectionLevel == "NONE" ? Color.kfError : Color.kfTextMuted)
                            }
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.kfTextMuted)
                        }
                    }
                }
                .accessibilityIdentifier("haven-row")
            } else {
                NavigationLink {
                    PaywallView()
                        .environmentObject(storeKit)
                } label: {
                    SettingsRow(icon: "slider.horizontal.3", label: "Configure Filters") {
                        HStack(spacing: 4) {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.kfAccentBlue)
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
            // Only load preferences once per SettingsView session — they're cached
            // and reloaded on server change via vpnServerDidChange notification.
            guard !havenPrefsLoaded else { return }
            havenPrefsLoaded = true
            await haven.loadPreferences()
        }
    }

    // MARK: - Haven Insights card

    private var havenInsightsCard: some View {
        VStack(alignment: .leading, spacing: KFSpacing.md) {
            sectionHeader("Haven Insights")

            NavigationLink {
                DnsStatsView()
                    .environmentObject(haven)
            } label: {
                SettingsRow(icon: "chart.bar.fill", label: "Protection Stats") {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.kfTextMuted)
                }
            }
            .accessibilityIdentifier("stats-row")

            Divider().background(Color.kfBorder)

            NavigationLink {
                AchievementsView()
                    .environmentObject(haven)
            } label: {
                SettingsRow(icon: "trophy.fill", label: "Achievements") {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.kfTextMuted)
                }
            }
        }
        .padding(KFSpacing.md)
        .kfCard()
    }

    // MARK: - Token card

    private var tokenCard: some View {
        VStack(alignment: .leading, spacing: KFSpacing.md) {
            sectionHeader("Your Token")

            if let token = KeychainHelper.shared.readOptional(for: .subscriptionToken) {
                HStack(spacing: KFSpacing.sm) {
                    Image(systemName: "key.horizontal.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.kfAccentBlue)
                        .frame(width: 20)

                    Text(tokenVisible ? token : maskedToken(token))
                        .font(KFFont.mono(12))
                        .foregroundStyle(Color.kfTextSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    Button {
                        tokenVisible.toggle()
                    } label: {
                        Image(systemName: tokenVisible ? "eye.slash.fill" : "eye.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.kfTextMuted)
                    }
                    .buttonStyle(.plain)

                    Button {
                        UIPasteboard.general.string = token
                        tokenCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { tokenCopied = false }
                    } label: {
                        Image(systemName: tokenCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 14))
                            .foregroundStyle(tokenCopied ? Color.kfConnected : Color.kfTextMuted)
                    }
                    .buttonStyle(.plain)
                }

                Text("This is your access token. Store it safely — it can restore your subscription on any device.")
                    .font(KFFont.caption(12))
                    .foregroundStyle(Color.kfTextMuted)
                    .padding(.leading, 28)
                    .fixedSize(horizontal: false, vertical: true)

            } else {
                Text("No token stored on this device.")
                    .font(KFFont.body(14))
                    .foregroundStyle(Color.kfTextMuted)
            }
        }
        .padding(KFSpacing.md)
        .kfCard()
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
                        KataProgressRing()
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.kfTextMuted)
                    }
                }
            }
            .disabled(isRestoring)

        }
        .padding(KFSpacing.md)
        .kfCard()
    }

    // MARK: - Support card

    private var supportCard: some View {
        VStack(alignment: .leading, spacing: KFSpacing.md) {
            sectionHeader("Support")

            HStack(spacing: KFSpacing.sm) {
                Circle()
                    .fill(platformStatus == nil ? Color.kfTextMuted :
                          platformStatus!.isHealthy ? Color.kfConnected :
                          platformStatus!.isDegraded ? Color.kfConnecting : Color.kfError)
                    .frame(width: 8, height: 8)
                    .padding(.leading, 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text("System Status")
                        .font(KFFont.body(14))
                        .foregroundStyle(.white)
                    Text(platformStatus?.displayStatus ?? (statusCheckDone ? "Unavailable" : "Checking…"))
                        .font(KFFont.caption(12))
                        .foregroundStyle(Color.kfTextMuted)
                }
                Spacer()
            }

            Divider().background(Color.kfBorder)

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
                    Text("Email registration is optional. Without one, recovery requires App Store restore or your original token. Register an email in Security to enable email-based recovery.")
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

            Button { showIdentityLink = true } label: {
                SettingsRow(icon: identityLinked ? "checkmark.shield.fill" : "link.badge.plus",
                            label: identityLinked ? "Recovery Identity Linked" : "Link Recovery Identity") {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.kfTextMuted)
                }
            }
            .foregroundStyle(identityLinked ? Color.kfConnected : Color.kfTextPrimary)
            .sheet(isPresented: $showIdentityLink) {
                identityLinkSheet
            }

            Divider().background(Color.kfBorder)

            Button { showSignOutAlert = true } label: {
                SettingsRow(icon: "rectangle.portrait.and.arrow.right", label: "Sign Out") {
                    EmptyView()
                }
                .foregroundStyle(Color.kfError)
            }

            Divider().background(Color.kfBorder)

            Button {
                Task { await vpn.disconnect() }
            } label: {
                SettingsRow(icon: "wifi.slash", label: "Force Disconnect") {
                    EmptyView()
                }
                .foregroundStyle(Color.kfError)
            }
        }
        .padding(KFSpacing.md)
        .kfCard()
    }

    private var identityLinkSheet: some View {
        ZStack {
            Color.kfBackground.ignoresSafeArea()
            VStack(alignment: .leading, spacing: KFSpacing.lg) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Link Recovery Identity")
                            .font(KFFont.heading(20))
                            .foregroundStyle(.white)
                        Text("Optional — but if you ever lose your token and aren't on the App Store, this is how we get you back in.")
                            .font(KFFont.caption(13))
                            .foregroundStyle(Color.kfTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button {
                        showIdentityLink = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(Color.kfTextMuted)
                    }
                }

                TextField("your@email.com", text: $identityLinkEmail)
                    .font(KFFont.body(15))
                    .foregroundStyle(Color.kfTextPrimary)
                    .autocapitalization(.none)
                    .keyboardType(.emailAddress)
                    .padding(KFSpacing.sm)
                    .background(Color.kfSurfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: KFRadius.md, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: KFRadius.md, style: .continuous).stroke(Color.kfBorder, lineWidth: 1))

                if let err = identityLinkError {
                    Text(err)
                        .font(KFFont.caption(12))
                        .foregroundStyle(Color.kfError)
                }

                Button {
                    Task {
                        isLinkingIdentity = true
                        identityLinkError = nil
                        defer { isLinkingIdentity = false }
                        do {
                            let _ = try await APIClient.shared.linkIdentity(type: "email", value: identityLinkEmail.trimmingCharacters(in: .whitespacesAndNewlines))
                            UserDefaults.standard.set(true, forKey: "identityLinked")
                            identityLinked = true
                            showIdentityLink = false
                        } catch {
                            identityLinkError = "Failed to link: \(error.localizedDescription)"
                        }
                    }
                } label: {
                    Group {
                        if isLinkingIdentity {
                            KataProgressRing()
                        } else {
                            Text("Link Email")
                                .font(KFFont.body(15))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, KFSpacing.sm)
                    .background(identityLinkEmail.isEmpty || isLinkingIdentity ? Color.kfAccentBlue.opacity(0.4) : Color.kfAccentBlue)
                    .clipShape(RoundedRectangle(cornerRadius: KFRadius.lg, style: .continuous))
                }
                .disabled(identityLinkEmail.isEmpty || isLinkingIdentity)

                Spacer()
            }
            .padding(KFSpacing.lg)
        }
        .presentationDetents([.medium])
    }

    // MARK: - Debug card (admin token only)

    private var isAdminToken: Bool {
        KeychainHelper.shared.readOptional(for: .tokenIsAdmin) == "1"
    }

    @ObservedObject private var debugLogger = DebugLogger.shared

    private var debugCard: some View {
        VStack(alignment: .leading, spacing: KFSpacing.md) {
            sectionHeader("Developer")

            Toggle(isOn: $debugLogger.isEnabled) {
                HStack(spacing: KFSpacing.sm) {
                    Image(systemName: "ant.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.kfAccentPurple)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Debug Mode")
                            .font(KFFont.body(14))
                            .foregroundStyle(.white)
                        Text("Captures API calls, tunnel events, DNS tests. Founder only.")
                            .font(KFFont.caption(12))
                            .foregroundStyle(Color.kfTextMuted)
                    }
                }
            }
            .tint(Color.kfAccentPurple)

            if debugLogger.isEnabled {
                Divider().background(Color.kfBorder)

                NavigationLink {
                    DebugLogView()
                        .environmentObject(vpn)
                } label: {
                    SettingsRow(icon: "doc.text.magnifyingglass", label: "View Debug Log") {
                        HStack(spacing: 4) {
                            Text("\(debugLogger.entries.count)")
                                .font(KFFont.caption(12, weight: .semibold))
                                .foregroundStyle(Color.kfAccentPurple)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.kfTextMuted)
                        }
                    }
                }

                if let report = vpn.healthReport {
                    Divider().background(Color.kfBorder)

                    HStack(spacing: KFSpacing.sm) {
                        Image(systemName: report.isHealthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(report.isHealthy ? Color.kfConnected : Color.kfError)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Tunnel Health")
                                .font(KFFont.body(14))
                                .foregroundStyle(.white)
                            Text(report.diagnosis)
                                .font(KFFont.caption(12))
                                .foregroundStyle(Color.kfTextMuted)
                        }
                    }
                }
            }
        }
        .padding(KFSpacing.md)
        .kfCard()
    }

    // MARK: - Diagnostics card

    private var diagnosticsCard: some View {
        VStack(alignment: .leading, spacing: KFSpacing.md) {
            sectionHeader("Diagnostics")

            NavigationLink {
                AppGroupDiagnosticsView()
            } label: {
                SettingsRow(icon: "checklist", label: "App Group Diagnostics") {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.kfTextMuted)
                }
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
            await vpn.revokePeer()
            _ = try? vpn.generateKeypair()
            // Auto-provision with new keys — no force-close required
            await vpn.autoProvisionIfNeeded()
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    private func maskedToken(_ token: String) -> String {
        guard token.count > 8 else { return String(repeating: "•", count: token.count) }
        let prefix = String(token.prefix(6))
        return prefix + String(repeating: "•", count: min(token.count - 6, 16))
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
