// MacMainView.swift
// WraithVPNMac
//
// Primary app window — full VPN controls. Mirrors the menubar popover
// but in a full-size persistent window suitable for leaving open.

import SwiftUI
import KatafractStyle

struct MacMainView: View {

    @EnvironmentObject var vpn:      WireGuardManager
    @EnvironmentObject var servers:  ServerListManager
    @EnvironmentObject var storeKit: StoreKitManager
    @EnvironmentObject var haven:    HavenDNSManager
    @Environment(\.openWindow) private var openWindow

    @AppStorage("simpleMode") private var simpleMode = true
    @State private var showServerList = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var showRegionPicker = false
    @State private var showMultiHopPicker = false
    @State private var showUpgradeSheet = false
    @State private var upgradeReason: UpgradeReason = .vpnRequiresEnclave
    @State private var multiHopEnabled = false

    var body: some View {
        VStack(spacing: 0) {
            statusSection
            Divider().background(Color.kfBorder)
            serverSection
            if !simpleMode {
                Divider().background(Color.kfBorder)
                advancedSection
            }
            Divider().background(Color.kfBorder)
            havenSection
            Divider().background(Color.kfBorder)
            footerBar
        }
        .frame(width: 440)
        .background(Color.kfBackground)
        .preferredColorScheme(.dark)
        .alert("Connection Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
        .sheet(isPresented: $showRegionPicker) {
            MacRegionPickerView()
                .environmentObject(vpn)
                .environmentObject(servers)
        }
        .sheet(isPresented: $showMultiHopPicker) {
            MacMultiHopPickerView()
                .environmentObject(vpn)
                .environmentObject(servers)
        }
        .sheet(isPresented: $showUpgradeSheet) {
            MacUpgradeSheet(reason: upgradeReason)
                .environmentObject(storeKit)
        }
        .task {
            await servers.refresh()
            await haven.refreshStatus()
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        VStack(spacing: 16) {
            // Shield
            ZStack {
                Circle()
                    .fill(statusGlowColor.opacity(0.12))
                    .frame(width: 88, height: 88)
                Circle()
                    .fill(statusGlowColor.opacity(0.07))
                    .frame(width: 72, height: 72)
                Group {
                    if #available(macOS 14.0, *) {
                        Image(systemName: statusIcon)
                            .font(.system(size: 36, weight: .semibold))
                            .foregroundStyle(statusGlowColor)
                            .contentTransition(.symbolEffect(.replace))
                    } else {
                        Image(systemName: statusIcon)
                            .font(.system(size: 36, weight: .semibold))
                            .foregroundStyle(statusGlowColor)
                    }
                }
            }
            .animation(.easeInOut(duration: 0.35), value: vpn.status)

            VStack(spacing: 4) {
                Text(vpn.status.label.uppercased())
                    .font(KFFont.heading(15))
                    .foregroundStyle(statusGlowColor)
                    .animation(.easeInOut(duration: 0.3), value: vpn.status)

                if vpn.status == .connected {
                    HStack(spacing: 6) {
                        if let ip = vpn.exitIP ?? vpn.assignedIP {
                            Text(ip)
                                .font(KFFont.mono(12))
                                .foregroundStyle(Color.kfTextMuted)
                        }
                        if let since = vpn.connectedSince {
                            Text("·")
                                .foregroundStyle(Color.kfTextMuted)
                            Text(since, style: .timer)
                                .font(KFFont.mono(12))
                                .foregroundStyle(Color.kfTextMuted)
                                .monospacedDigit()
                        }
                    }
                } else {
                    Text(storeKit.subscription?.planDisplayName ?? "Not activated")
                        .font(KFFont.caption(12))
                        .foregroundStyle(Color.kfTextMuted)
                }
            }

            // Connect button
            Button(action: handleConnectTap) {
                HStack(spacing: 8) {
                    if vpn.status == .connecting || vpn.status == .disconnecting {
                        KataProgressRing()
                            .scaleEffect(0.7)
                            .tint(.white)
                    }
                    Text(connectButtonLabel)
                        .font(KFFont.caption(13, weight: .bold))
                        .kerning(1.2)
                }
                .frame(width: 200, height: 38)
                .background(connectButtonColor)
                .clipShape(RoundedRectangle(cornerRadius: KFRadius.sm, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(vpn.status == .connecting || vpn.status == .disconnecting)
        }
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Server

    private var serverSection: some View {
        VStack(spacing: 0) {
            Button {
                if !simpleMode {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showServerList.toggle()
                    }
                    if !showServerList { Task { await servers.refresh() } }
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: simpleMode ? "sparkles" : "location.north.line.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.kfAccentBlue)
                        .frame(width: 28, height: 28)
                        .background(Color.kfAccentBlue.opacity(0.12))
                        .clipShape(Circle())

                    VStack(alignment: .leading, spacing: 2) {
                        Text("SERVER")
                            .font(KFFont.caption(9, weight: .bold))
                            .kerning(1.2)
                            .foregroundStyle(Color.kfTextMuted)
                        Text(serverDisplayName)
                            .font(KFFont.body(14))
                            .foregroundStyle(.white)
                    }
                    Spacer()
                    if !simpleMode {
                        // Region picker button
                        Button {
                            showRegionPicker = true
                        } label: {
                            HStack(spacing: 4) {
                                Text(currentRegionLabel)
                                    .font(KFFont.caption(11))
                                    .foregroundStyle(Color.kfAccentBlue)
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 9))
                                    .foregroundStyle(Color.kfAccentBlue)
                            }
                        }
                        .buttonStyle(.plain)

                        Image(systemName: showServerList ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.kfTextMuted)
                            .padding(.leading, 4)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)

            if showServerList && !simpleMode {
                Divider().background(Color.kfBorder).padding(.horizontal, 20)
                serverListView
            }
        }
    }

    private var serverListView: some View {
        Group {
            if servers.isLoading && servers.servers.isEmpty {
                HStack { Spacer(); KataProgressRing(size: 20); Spacer() }
                    .padding(.vertical, 14)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(servers.servers) { entry in
                            serverRow(entry: entry)
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
        }
        .background(Color.kfSurface.opacity(0.5))
    }

    private func serverRow(entry: ServerLatency) -> some View {
        let isSelected = servers.selectedServer?.nodeId == entry.server.nodeId
        return Button {
            servers.selectServer(entry.server)
            withAnimation { showServerList = false }
        } label: {
            HStack(spacing: 12) {
                Text(entry.server.flagEmoji).font(.system(size: 18))
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.server.cityName)
                        .font(KFFont.body(13))
                        .foregroundStyle(isSelected ? Color.kfAccentBlue : .white)
                    Text(entry.server.region.uppercased())
                        .font(KFFont.caption(9, weight: .medium))
                        .foregroundStyle(Color.kfTextMuted)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.kfAccentBlue)
                } else if let ms = entry.milliseconds {
                    Text("\(Int(ms)) ms")
                        .font(KFFont.mono(10))
                        .foregroundStyle(entry.latencyTier.swiftUIColor)
                } else {
                    Text("—").font(KFFont.mono(10)).foregroundStyle(Color.kfTextMuted)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(isSelected ? Color.kfAccentBlue.opacity(0.08) : Color.clear)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Advanced section (kill switch, multi-hop, stay connected)

    private var advancedSection: some View {
        VStack(spacing: 0) {
            // Kill Switch
            HStack(spacing: 12) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.kfAccentPurple)
                    .frame(width: 28, height: 28)
                    .background(Color.kfAccentPurple.opacity(0.12))
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("KILL SWITCH")
                        .font(KFFont.caption(9, weight: .bold))
                        .kerning(1.2)
                        .foregroundStyle(Color.kfTextMuted)
                    Text("Block all traffic if tunnel drops")
                        .font(KFFont.body(13))
                        .foregroundStyle(.white)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { vpn.tunnelMode == .full },
                    set: { on in Task { await vpn.setTunnelMode(on ? .full : .standard) } }
                ))
                .toggleStyle(.switch)
                .scaleEffect(0.8)
                .tint(Color.kfAccentPurple)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            Divider().background(Color.kfBorder).padding(.horizontal, 20)

            // Multi-Hop toggle
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(hex: "#f59e0b"))
                    .frame(width: 28, height: 28)
                    .background(Color(hex: "#f59e0b").opacity(0.12))
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("MULTI-HOP")
                        .font(KFFont.caption(9, weight: .bold))
                        .kerning(1.2)
                        .foregroundStyle(Color.kfTextMuted)
                    Text(storeKit.hasMultiHop ? "Double-tunnel routing" : "Enclave+ feature")
                        .font(KFFont.body(13))
                        .foregroundStyle(storeKit.hasMultiHop ? .white : Color.kfTextMuted)
                }
                Spacer()
                Toggle("", isOn: $multiHopEnabled)
                    .toggleStyle(.switch)
                    .scaleEffect(0.8)
                    .tint(Color(hex: "#f59e0b"))
                    .disabled(!storeKit.hasMultiHop)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            Divider().background(Color.kfBorder).padding(.horizontal, 20)

            // Stay Connected
            HStack(spacing: 12) {
                Image(systemName: "wifi")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.kfConnected)
                    .frame(width: 28, height: 28)
                    .background(Color.kfConnected.opacity(0.12))
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("STAY CONNECTED")
                        .font(KFFont.caption(9, weight: .bold))
                        .kerning(1.2)
                        .foregroundStyle(Color.kfTextMuted)
                    Text("Reconnect automatically on network change")
                        .font(KFFont.body(13))
                        .foregroundStyle(.white)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { vpn.autoConnectEnabled },
                    set: { on in Task { await vpn.setAutoConnect(on) } }
                ))
                .toggleStyle(.switch)
                .scaleEffect(0.8)
                .tint(Color.kfConnected)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Haven DNS

    private var havenSection: some View {
        HStack(spacing: 12) {
            Image(systemName: haven.isEnabled ? "shield.checkered" : "shield.slash")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(haven.isEnabled ? Color.kfConnected : Color.kfTextMuted)
                .frame(width: 28, height: 28)
                .background((haven.isEnabled ? Color.kfConnected : Color.kfTextMuted).opacity(0.12))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text("HAVEN DNS")
                    .font(KFFont.caption(9, weight: .bold))
                    .kerning(1.2)
                    .foregroundStyle(Color.kfTextMuted)
                Text(haven.isEnabled ? "Ad & tracker blocking active" : "Protection off")
                    .font(KFFont.body(13))
                    .foregroundStyle(.white)
            }
            Spacer()
            if haven.isLoading {
                KataProgressRing(size: 20)
            } else {
                Toggle("", isOn: Binding(
                    get: { haven.isEnabled },
                    set: { _ in Task { await haven.toggle() } }
                ))
                .toggleStyle(.switch)
                .scaleEffect(0.8)
                .tint(Color.kfConnected)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack {
            // Mode toggle
            Button {
                simpleMode.toggle()
                if simpleMode { Task { await vpn.setTunnelMode(.standard) } }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: simpleMode ? "sparkles" : "slider.horizontal.3")
                        .font(.system(size: 11))
                    Text(simpleMode ? "Simple" : "Advanced")
                        .font(KFFont.caption(11))
                }
                .foregroundStyle(simpleMode ? Color.kfAccentBlue : Color.kfAccentPurple)
            }
            .buttonStyle(.plain)

            Spacer()

            Button("Account & Settings") {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            }
            .buttonStyle(.plain)
            .font(KFFont.caption(11))
            .foregroundStyle(Color.kfTextMuted)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    // MARK: - Helpers

    private func handleConnectTap() {
        // Upgrade gate
        guard storeKit.hasVPN else {
            upgradeReason = .vpnRequiresEnclave
            showUpgradeSheet = true
            return
        }

        // Multi-hop path
        if multiHopEnabled && storeKit.hasMultiHop {
            showMultiHopPicker = true
            return
        }

        Task {
            do {
                if vpn.status == .connected {
                    vpn.disconnect()
                } else if simpleMode {
                    if vpn.isProvisioned {
                        try await vpn.connect()
                    } else {
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
                    try await vpn.connectToServer(server)
                } else {
                    let nearest = try await APIClient.shared.fetchNearestServer()
                    try await vpn.connectToServer(nearest)
                }
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }

    private var currentRegionLabel: String {
        if let region = vpn.connectedServer?.region {
            return regionShortLabel(region)
        }
        return "Auto"
    }

    private func regionShortLabel(_ regionId: String) -> String {
        switch regionId {
        case "us-east":      return "US East"
        case "us-west":      return "US West"
        case "eu-west":      return "EU West"
        case "eu-north":     return "EU North"
        case "ap-southeast": return "SE Asia"
        case "ap-northeast": return "Japan"
        case "ap-south":     return "India"
        default:             return regionId
        }
    }

    private var serverDisplayName: String {
        if simpleMode { return vpn.connectedServer?.cityName ?? "Nearest · GeoIP" }
        return servers.selectedServer?.cityName ?? "Select a server"
    }

    private var connectButtonLabel: String {
        switch vpn.status {
        case .connected:                    return "DISCONNECT"
        case .connecting:                   return "CONNECTING"
        case .disconnecting:                return "DISCONNECTING"
        default:                            return "CONNECT"
        }
    }

    private var connectButtonColor: Color {
        switch vpn.status {
        case .connected:                    return Color.kfError.opacity(0.85)
        case .connecting, .disconnecting:   return Color.kfConnecting.opacity(0.85)
        default:                            return Color.kfAccentBlue
        }
    }

    private var statusIcon: String {
        switch vpn.status {
        case .connected:                    return "shield.fill"
        case .connecting, .disconnecting:   return "shield.lefthalf.filled"
        default:                            return "shield"
        }
    }

    private var statusGlowColor: Color {
        switch vpn.status {
        case .connected:                    return .kfConnected
        case .connecting, .disconnecting:   return .kfConnecting
        default:                            return .kfAccentBlue
        }
    }
}
