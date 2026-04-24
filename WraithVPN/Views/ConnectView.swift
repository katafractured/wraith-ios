// ConnectView.swift
// WraithVPN
//
// Main screen: animated connect button, status label, selected server location,
// current assigned IP when connected, and quick-access to server picker.

import SwiftUI
import KatafractStyle

struct ConnectView: View {

    @EnvironmentObject var vpn:      WireGuardManager
    @EnvironmentObject var servers:  ServerListManager
    @EnvironmentObject var storeKit: StoreKitManager

    @AppStorage("simpleMode")          private var simpleMode          = true
    @AppStorage("multiHopMode")        private var multiHopMode        = false
    @AppStorage("hopModeExplicitlySet") private var hopModeExplicitlySet = false

    @State private var showRegionPicker        = false
    @State private var showMultiHopPicker      = false
    @State private var errorMessage: String? = nil
    @State private var showError          = false
    @State private var upgradeReason: UpgradeReason? = nil
    @State private var showHopSwitchConfirm    = false
    @State private var pendingHopMode: Bool?   = nil
    @State private var suppressNextHopModeChange = false
    @State private var hiddenTapCount = 0
    @State private var showCodeSheet = false
    @State private var tapResetTimer: Task<Void, Never>? = nil

    private var isAnimatingRing: Bool {
        vpn.status == .connecting || vpn.status == .disconnecting || vpn.isProvisioning
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { proxy in
            let layout = ConnectLayout(proxy: proxy)

            ZStack {
                backgroundGradient
                    .ignoresSafeArea()

                // Gold hairline border when connected — the signal IS the border
                if vpn.status == .connected && !storeKit.isHavenOnly {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.kataGold.opacity(0.55), lineWidth: 0.5)
                        .padding(.horizontal, 16)
                        .padding(.top, max(proxy.safeAreaInsets.top - 4, 4))
                        .padding(.bottom, max(proxy.safeAreaInsets.bottom - 4, 4))
                        .transition(.opacity.animation(.easeInOut(duration: 0.6)))
                }

                VStack(spacing: layout.sectionSpacing) {
                    header
                    heroSection(layout: layout)
                    connectionSummary
                    hopModeSection
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, KFSpacing.lg)
                .padding(.top, layout.topPadding)
                .padding(.bottom, layout.bottomPadding)
            }
        }
        .sheet(isPresented: $showRegionPicker) {
            RegionPickerView()
                .environmentObject(vpn)
                .environmentObject(servers)
        }
        .sheet(isPresented: $showMultiHopPicker) {
            MultiHopPickerSheet()
                .environmentObject(vpn)
                .environmentObject(servers)
        }
        .sheet(item: $upgradeReason) { reason in
            UpgradeSheet(reason: reason)
        }
        .alert("Connection Error", isPresented: $showError, actions: {
            Button("OK", role: .cancel) {}
        }, message: {
            Text(errorMessage ?? "Unknown error")
        })
        .preferredColorScheme(.dark)
        .task {
            await servers.refresh()
            syncSelectedToConnected()
            if vpn.isMultiHop {
                multiHopMode = true
            } else {
                applyDefaultHopMode()
            }
        }
        .onChange(of: vpn.connectedServer?.nodeId) { _, _ in
            syncSelectedToConnected()
        }
        .onChange(of: vpn.isMultiHop) { _, newValue in
            if newValue { multiHopMode = true }
        }
        .onChange(of: vpn.status) { _, newStatus in
            guard newStatus == .disconnected, let pending = pendingHopMode else { return }
            pendingHopMode = nil
            suppressNextHopModeChange = true
            multiHopMode = pending
            hopModeExplicitlySet = true
            if pending {
                showMultiHopPicker = true
            } else {
                showRegionPicker = true
            }
        }
        .onChange(of: storeKit.hasMultiHop) { _, _ in
            applyDefaultHopMode()
        }
        .onChange(of: multiHopMode) { oldValue, newValue in
            if suppressNextHopModeChange {
                suppressNextHopModeChange = false
                return
            }
            if newValue && !storeKit.hasMultiHop {
                upgradeReason = .multiHopRequiresSovereign
                suppressNextHopModeChange = true
                multiHopMode = false
                return
            }
            hopModeExplicitlySet = true
            if vpn.status == .connected || vpn.status == .connecting {
                suppressNextHopModeChange = true
                multiHopMode = oldValue
                pendingHopMode = newValue
                showHopSwitchConfirm = true
            }
        }
        .alert(
            "Disconnect to Switch Mode?",
            isPresented: $showHopSwitchConfirm
        ) {
            Button("Disconnect & Switch", role: .destructive) {
                vpn.disconnect()
            }
            Button("Cancel", role: .cancel) {
                pendingHopMode = nil
            }
        } message: {
            let target = (pendingHopMode ?? !multiHopMode) ? "Multi-Hop" : "Single Hop"
            Text("Switching to \(target) requires disconnecting your current VPN session.")
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: vpn.status == .connected)
        .sensoryFeedback(.impact(weight: .light),  trigger: vpn.status == .disconnected)
        .sheet(isPresented: $showCodeSheet) {
            CodeRedemptionView()
        }
    }

    // MARK: - Helpers

    private func applyDefaultHopMode() {
        guard storeKit.hasMultiHop, !hopModeExplicitlySet else { return }
        multiHopMode = true
    }

    private func syncSelectedToConnected() {
        guard let nodeId = vpn.connectedServer?.nodeId else { return }
        if let match = servers.servers.first(where: { $0.server.nodeId == nodeId }) {
            servers.selectedServer = match.server
        }
    }

    // MARK: - Hop mode section

    private var hopModeSection: some View {
        VStack(spacing: KFSpacing.sm) {
            if storeKit.hasVPN && (storeKit.hasSovereign || storeKit.isFounder) {
                Picker("Hop Mode", selection: $multiHopMode) {
                    Text("Single Hop").tag(false)
                    Text("Multi-Hop").tag(true)
                }
                .pickerStyle(.segmented)
            }

            if !multiHopMode {
                serverButton
            } else if vpn.isMultiHop,
                      let entry = vpn.multiHopEntryServer,
                      let exit  = vpn.multiHopExitServer {
                Button { showMultiHopPicker = true } label: {
                    HStack(spacing: KFSpacing.md) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Color(hex: "#f59e0b"))
                            .frame(width: 40, height: 40)
                            .background(Color(hex: "#f59e0b").opacity(0.12))
                            .clipShape(Circle())
                        VStack(alignment: .leading, spacing: 4) {
                            Text("MULTI-HOP ROUTE")
                                .font(KFFont.caption(10, weight: .bold))
                                .kerning(1.3)
                                .foregroundStyle(Color.kfTextMuted)
                            HStack(spacing: 6) {
                                Text(entry.flagEmoji)
                                Text(entry.cityName)
                                    .foregroundStyle(.white)
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Color.kfTextMuted)
                                Text(exit.flagEmoji)
                                Text(exit.cityName)
                                    .foregroundStyle(.white)
                            }
                            .font(KFFont.heading(15))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            Text("Tap to change route")
                                .font(KFFont.caption(12))
                                .foregroundStyle(Color.kfTextMuted)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.kfTextMuted)
                    }
                    .padding(KFSpacing.md)
                    .kfCard()
                }
            }
        }
    }

    // MARK: - Sub-views

    private var backgroundGradient: some View {
        ZStack {
            Color.kfBackground
            RadialGradient(
                colors: [
                    vpn.status == .connected
                        ? Color.kataGold.opacity(0.06)
                        : Color.kfAccentPurple.opacity(0.08),
                    Color.clear
                ],
                center: .top,
                startRadius: 0,
                endRadius: 400
            )
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("WRAITH")
                    .font(KFFont.caption(11, weight: .bold))
                    .kerning(3)
                    .foregroundStyle(Color.kfTextMuted)
                Text("VPN")
                    .font(KFFont.display(28))
                    .foregroundStyle(.white)
            }
            Spacer()
            NavigationLink(destination: SettingsView()) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(Color.kfSurface.opacity(0.9))
                    .clipShape(Circle())
                    .overlay(
                        Circle()
                            .stroke(Color.kfBorder, lineWidth: 1)
                    )
            }
            .accessibilityIdentifier("settings-tab")
        }
        .onTapGesture {
            hiddenTapCount += 1
            if hiddenTapCount >= 7 {
                hiddenTapCount = 0
                KataHaptic.unlocked.fire()
                showCodeSheet = true
            }
            // Reset counter after 3 seconds of inactivity
            tapResetTimer?.cancel()
            tapResetTimer = Task {
                try? await Task.sleep(for: .seconds(3))
                hiddenTapCount = 0
            }
        }
    }

    // MARK: - Connect button

    private var connectButton: some View {
        ZStack {
            ConnectButtonView(isAnimatingRing: isAnimatingRing, onTap: handleConnectTap)
                .environmentObject(vpn)
                .opacity(storeKit.isHavenOnly ? 0.2 : 1)

            if storeKit.isHavenOnly {
                Button {
                    upgradeReason = .vpnRequiresEnclave
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "shield.checkmark.fill")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(Color(hex: "#38bdf8"))
                        Text("DNS Active")
                            .font(KFFont.caption(13, weight: .bold))
                            .foregroundStyle(Color(hex: "#38bdf8"))
                        Text("Tap to add VPN")
                            .font(KFFont.caption(11))
                            .foregroundStyle(Color.kfTextMuted)
                    }
                }
            }
        }
        .accessibilityIdentifier("connect-button")
    }

    private func heroSection(layout: ConnectLayout) -> some View {
        VStack(spacing: layout.heroSpacing) {
            connectButton
            statusSection
        }
        .frame(maxWidth: .infinity)
        .padding(.top, layout.heroTopPadding)
    }

    // MARK: - Status section (post-connect: no green, typography is the signal)

    private var statusSection: some View {
        VStack(spacing: KFSpacing.xs) {
            if vpn.status == .connected && !storeKit.isHavenOnly {
                // Gold-typography sealed state — no green, no "Connected"
                Text("Inside the Enclave.")
                    .font(.kataDisplay(22, weight: .regular))
                    .foregroundStyle(Color.kataChampagne)
                    .animation(.easeInOut(duration: 0.4), value: vpn.status)
                    .transition(.opacity.combined(with: .move(edge: .top)))

                if let since = vpn.connectedSince {
                    Text(since, style: .timer)
                        .font(.kataMono(12))
                        .foregroundStyle(Color.kataGold.opacity(0.7))
                        .monospacedDigit()
                }
                if let ip = vpn.exitIP ?? vpn.assignedIP {
                    HStack(spacing: KFSpacing.xs) {
                        Image(systemName: "globe")
                            .font(.system(size: 11))
                        Text(ip)
                            .font(.kataMono(12))
                    }
                    .foregroundStyle(Color.kataChampagne.opacity(0.5))
                }
            } else {
                Text(storeKit.isHavenOnly ? "DNS Protected" : vpn.status.label)
                    .font(KFFont.heading(24))
                    .foregroundStyle(storeKit.isHavenOnly ? Color(hex: "#38bdf8") : Color.kfTextPrimary)
                    .animation(.easeInOut(duration: 0.3), value: vpn.status)
                    .contentTransition(.numericText())

                Text(statusCaption)
                    .font(KFFont.body(14))
                    .foregroundStyle(Color.kfTextSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: vpn.status == .connected)
    }

    private var connectionSummary: some View {
        VStack(spacing: KFSpacing.sm) {
            if vpn.isMultiHop, let entry = vpn.multiHopEntryServer, let exit = vpn.multiHopExitServer {
                HStack(spacing: KFSpacing.sm) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.kfAccentBlue)
                        .frame(width: 28, height: 28)
                        .background(Color.kfAccentBlue.opacity(0.12))
                        .clipShape(Circle())

                    VStack(alignment: .leading, spacing: 2) {
                        Text("ROUTE".uppercased())
                            .font(KFFont.caption(10, weight: .bold))
                            .kerning(1.2)
                            .foregroundStyle(Color.kfTextMuted)
                        HStack(spacing: 6) {
                            Text(entry.flagEmoji)
                                .font(.system(size: 13))
                            Text(entry.cityName)
                                .font(KFFont.body(14))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Image(systemName: "arrow.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.kfTextMuted)
                            Text(exit.flagEmoji)
                                .font(.system(size: 13))
                            Text(exit.cityName)
                                .font(KFFont.body(14))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                        }
                        .minimumScaleFactor(0.75)
                        .lineLimit(1)
                    }

                    Spacer(minLength: 0)
                }
                .padding(KFSpacing.sm)
                .frame(maxWidth: .infinity)
                .background(Color.kfSurface.opacity(0.92))
                .clipShape(RoundedRectangle(cornerRadius: KFRadius.md, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: KFRadius.md, style: .continuous)
                        .stroke(Color.kfBorder, lineWidth: 1)
                )

                summaryPill(
                    title: "Mode",
                    value: vpn.status == .connected ? "Protected" : "Standby",
                    icon: vpn.status == .connected ? "shield.fill" : "moon.stars.fill"
                )
            } else {
                HStack(spacing: KFSpacing.md) {
                    summaryPill(
                        title: "Route",
                        value: simpleMode
                            ? (vpn.connectedServer?.cityName ?? "Automatic")
                            : (servers.selectedServer?.cityName ?? "Automatic"),
                        icon: (simpleMode && vpn.connectedServer == nil) ? "sparkles" : "location.north.line.fill"
                    )
                    summaryPill(
                        title: "Mode",
                        value: vpn.status == .connected ? "Protected" : "Standby",
                        icon: vpn.status == .connected ? "shield.fill" : "moon.stars.fill"
                    )
                }
                if !simpleMode {
                    summaryPill(
                        title: "Kill Switch",
                        value: vpn.tunnelMode == .full ? "On" : "Off",
                        icon: vpn.tunnelMode == .full ? "lock.shield.fill" : "lock.shield"
                    )
                }
            }
        }
    }

    private func summaryPill(title: String, value: String, icon: String) -> some View {
        HStack(spacing: KFSpacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.kfAccentBlue)
                .frame(width: 28, height: 28)
                .background(Color.kfAccentBlue.opacity(0.12))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title.uppercased())
                    .font(KFFont.caption(10, weight: .bold))
                    .kerning(1.2)
                    .foregroundStyle(Color.kfTextMuted)
                Text(value)
                    .font(KFFont.body(14))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(KFSpacing.sm)
        .frame(maxWidth: .infinity)
        .background(Color.kfSurface.opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: KFRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: KFRadius.md, style: .continuous)
                .stroke(Color.kfBorder, lineWidth: 1)
        )
    }

    // MARK: - Server button

    private var serverButton: some View {
        Button {
            if !simpleMode { showRegionPicker = true }
        } label: {
            HStack(spacing: KFSpacing.md) {
                if simpleMode {
                    Image(systemName: "sparkles")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.kfAccentBlue)
                        .frame(width: 40, height: 40)
                        .background(Color.kfAccentBlue.opacity(0.12))
                        .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 4) {
                        Text("WRAITHGATE")
                            .font(KFFont.caption(10, weight: .bold))
                            .kerning(1.3)
                            .foregroundStyle(Color.kfTextMuted)
                        Text(vpn.connectedServer?.cityName ?? "Nearest Server")
                            .font(KFFont.heading(17))
                            .foregroundStyle(.white)
                        Text("Automatically selected for best speed")
                            .font(KFFont.caption(12))
                            .foregroundStyle(Color.kfTextMuted)
                    }
                } else if let server = servers.selectedServer {
                    Text(server.flagEmoji)
                        .font(.system(size: 26))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("WRAITHGATE")
                            .font(KFFont.caption(10, weight: .bold))
                            .kerning(1.3)
                            .foregroundStyle(Color.kfTextMuted)
                        Text(server.cityName)
                            .font(KFFont.heading(17))
                            .foregroundStyle(.white)
                        Text("Tap to change route")
                            .font(KFFont.caption(12))
                            .foregroundStyle(Color.kfTextMuted)
                    }
                } else {
                    Image(systemName: "globe.americas.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.kfAccentBlue)
                        .frame(width: 40, height: 40)
                        .background(Color.kfAccentBlue.opacity(0.12))
                        .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 4) {
                        Text("WRAITHGATE")
                            .font(KFFont.caption(10, weight: .bold))
                            .kerning(1.3)
                            .foregroundStyle(Color.kfTextMuted)
                        Text("Select Route")
                            .font(KFFont.heading(17))
                            .foregroundStyle(.white)
                    }
                }

                Spacer()

                if !simpleMode {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.kfTextMuted)
                }
            }
            .padding(KFSpacing.md)
            .kfCard()
        }
        .disabled(simpleMode || storeKit.isHavenOnly)
        .opacity(storeKit.isHavenOnly ? 0.4 : 1)
        .accessibilityIdentifier("region-button")
    }

    // MARK: - Actions

    private func handleConnectTap() {
        Task {
            do {
                if vpn.status == .connected || vpn.status == .connecting || vpn.isProvisioning {
                    vpn.disconnect()
                    return
                }

                if KeychainHelper.shared.readOptional(for: .subscriptionToken) == nil {
                    upgradeReason = .vpnRequiresEnclave
                    return
                }

                if storeKit.isHavenOnly {
                    upgradeReason = .vpnRequiresEnclave
                    return
                }

                if multiHopMode {
                    showMultiHopPicker = true
                    return
                }

                if simpleMode && !multiHopMode {
                    if vpn.isProvisioned && !vpn.isMultiHop {
                        try await vpn.connect()
                    } else {
                        vpn.setConnectingState()
                        let nearest = try await APIClient.shared.fetchNearestServer()
                        try await vpn.connectToServer(nearest)
                    }
                } else if vpn.isProvisioned,
                          let selected = servers.selectedServer,
                          selected.nodeId != vpn.connectedServer?.nodeId {
                    try await vpn.connectToServer(selected)
                } else if vpn.isProvisioned {
                    try await vpn.connect()
                } else if let server = servers.selectedServer {
                    vpn.setConnectingState()
                    try await vpn.connectToServer(server)
                } else {
                    vpn.setConnectingState()
                    let nearest = try await APIClient.shared.fetchNearestServer()
                    try await vpn.connectToServer(nearest)
                }
            } catch {
                errorMessage = error.localizedDescription
                showError = true
                vpn.status = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Computed helpers

    private var statusCaption: String {
        if storeKit.isHavenOnly {
            if storeKit.hasDNSSettings {
                return "Haven DNS is active. Upgrade to Enclave to enable the VPN tunnel."
            } else {
                return "Haven DNS is protecting your device. Upgrade to Haven Pro or Enclave for advanced features."
            }
        }
        if vpn.isAutoProvisioning {
            return "Setting up your secure route…"
        }
        switch vpn.status {
        case .connected:
            if vpn.isMultiHop {
                return "Double-encrypted. Neither hop sees your full picture."
            }
            return "Traffic is flowing through the Enclave."
        case .connecting:
            if vpn.isMultiHop {
                return "Building your double-hop route…"
            }
            return "Establishing a secure route through a WraithGate."
        case .disconnecting:
            return "Tearing down the current route."
        case .failed(let message):
            return message
        default:
            return vpn.isProvisioned
                ? "Ready to secure your connection."
                : "Tap connect to set up your route."
        }
    }
}

private struct ConnectLayout {
    let safeTop: CGFloat
    let safeBottom: CGFloat
    let height: CGFloat

    init(proxy: GeometryProxy) {
        safeTop = proxy.safeAreaInsets.top
        safeBottom = proxy.safeAreaInsets.bottom
        height = proxy.size.height
    }

    private var compact: Bool { height < 760 }

    var topPadding: CGFloat { safeTop + 10 }
    var bottomPadding: CGFloat { max(safeBottom, 18) }
    var sectionSpacing: CGFloat { compact ? 18 : 24 }
    var heroTopPadding: CGFloat { compact ? 6 : 18 }
    var heroSpacing: CGFloat { compact ? 22 : 28 }
}

// MARK: - Connect button view (concentric hairline rings + sapphire core)

private struct ConnectButtonView: View {

    @EnvironmentObject var vpn: WireGuardManager
    let isAnimatingRing: Bool
    let onTap: () -> Void

    // Canvas diameter: 260pt. Ring diameters: 180 / 216 / 252 (inner→outer).
    private let innerD:  CGFloat = 180
    private let middleD: CGFloat = 216
    private let outerD:  CGFloat = 252
    private let coreD:   CGFloat = 140

    @State private var innerPulse: CGFloat = 1.0

    var body: some View {
        Button(action: {
            Task { @MainActor in
                if vpn.status == .connected || vpn.status == .connecting || vpn.isProvisioning {
                    KataHaptic.destructive.fire()
                } else {
                    KataHaptic.unlocked.fire()
                }
                onTap()
            }
        }) {
            ZStack {
                // Outer ring — solid gold line when connected, hairline otherwise
                Circle()
                    .stroke(
                        vpn.status == .connected
                            ? Color.kataGold
                            : Color.kataGold.opacity(0.6),
                        lineWidth: vpn.status == .connected ? 1.0 : 0.5
                    )
                    .frame(width: outerD, height: outerD)
                    .opacity(vpn.status == .connected ? 1.0 : 0.8)
                    .animation(.easeInOut(duration: 0.6), value: vpn.status == .connected)

                // Middle ring
                Circle()
                    .stroke(Color.kataGold.opacity(0.8), lineWidth: 0.5)
                    .frame(width: middleD, height: middleD)
                    .opacity(vpn.status == .connected ? 0.3 : 0.8)
                    .animation(.easeInOut(duration: 0.6), value: vpn.status == .connected)

                // Inner ring — pulses during connecting
                Circle()
                    .stroke(Color.kataGold.opacity(1.0), lineWidth: 0.5)
                    .frame(width: innerD, height: innerD)
                    .scaleEffect(isAnimatingRing ? innerPulse : 1.0)
                    .opacity(vpn.status == .connected ? 0.3 : 1.0)
                    .animation(.easeInOut(duration: 0.6), value: vpn.status == .connected)

                // Sapphire core
                Circle()
                    .fill(Color.kataSapphire)
                    .frame(width: coreD, height: coreD)

                // Subtle glow behind core
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.kataSapphire.opacity(0.3), Color.clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: 80
                        )
                    )
                    .frame(width: innerD, height: innerD)

                // Label inside core
                coreLabel
            }
        }
        .buttonStyle(ScaleButtonStyle())
        .disabled(vpn.status == .disconnecting)
        .onAppear { startPulseIfNeeded() }
        .onChange(of: isAnimatingRing) { _, animating in
            if animating { startPulseIfNeeded() }
        }
    }

    private var coreLabel: some View {
        VStack(spacing: KFSpacing.xs) {
            Image(systemName: buttonIcon)
                .font(.system(size: 38, weight: .medium))
                .foregroundStyle(Color.kataIce)
                .animation(.easeInOut(duration: 0.3), value: vpn.status)
            Text(buttonLabel)
                .font(.kataMono(11, weight: .semibold))
                .kerning(1.4)
                .foregroundStyle(Color.kataChampagne.opacity(0.8))
        }
    }

    private func startPulseIfNeeded() {
        guard isAnimatingRing else { innerPulse = 1.0; return }
        withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
            innerPulse = 0.95
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                innerPulse = 1.05
            }
        }
    }

    private var buttonIcon: String {
        if vpn.isProvisioning { return "ellipsis" }
        switch vpn.status {
        case .connected:     return "power"
        case .connecting:    return "ellipsis"
        case .disconnecting: return "ellipsis"
        default:             return "power"
        }
    }

    private var buttonLabel: String {
        if vpn.isProvisioning { return "CANCEL" }
        switch vpn.status {
        case .connected:     return "DISCONNECT"
        case .connecting:    return "CANCEL"
        case .disconnecting: return "DISCONNECTING"
        default:             return "CONNECT"
        }
    }
}

// MARK: - Scale button style

struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        ConnectView()
            .environmentObject(WireGuardManager())
            .environmentObject(ServerListManager())
    }
}
