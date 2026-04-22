// MainMenuView.swift
// WraithVPNMac
//
// Primary menu-bar popover. Full dynamic VPN + Haven DNS + account management.
// Dynamic server list is fetched from the API — new nodes appear automatically.

import SwiftUI
import KatafractStyle

struct MainMenuView: View {

    @EnvironmentObject var vpn:      WireGuardManager
    @EnvironmentObject var servers:  ServerListManager
    @EnvironmentObject var storeKit: StoreKitManager
    @EnvironmentObject var haven:    HavenDNSManager
    @Environment(\.openWindow) private var openWindow

    @AppStorage("simpleMode") private var simpleMode = true
    @State private var showServerList = false
    @State private var errorMessage: String? = nil
    @State private var showError = false
    @State private var showRegionPicker = false
    @State private var showMultiHopPicker = false
    @State private var showUpgradeSheet = false
    @State private var upgradeReason: UpgradeReason = .vpnRequiresEnclave
    @State private var multiHopEnabled = false

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            Divider().background(Color.kfBorder)
            connectionSection
            Divider().background(Color.kfBorder)
            serverSection
            if !simpleMode {
                Divider().background(Color.kfBorder)
                advancedCompactSection
            }
            Divider().background(Color.kfBorder)
            havenSection
            Divider().background(Color.kfBorder)
            accountSection
            Divider().background(Color.kfBorder)
            footerSection
        }
        .frame(width: 300)
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

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(statusGlowColor.opacity(0.18))
                    .frame(width: 34, height: 34)
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(statusIconColor)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Wraith VPN")
                    .font(KFFont.heading(13))
                    .foregroundStyle(.white)
                Text(storeKit.subscription?.planDisplayName ?? "No subscription")
                    .font(KFFont.caption(11))
                    .foregroundStyle(Color.kfTextMuted)
            }
            Spacer()
            // Mode toggle
            Button {
                simpleMode.toggle()
                if simpleMode {
                    Task { await vpn.setTunnelMode(.standard) }
                }
            } label: {
                Image(systemName: simpleMode ? "sparkles" : "slider.horizontal.3")
                    .font(.system(size: 13))
                    .foregroundStyle(simpleMode ? Color.kfAccentBlue : Color.kfAccentPurple)
                    .frame(width: 28, height: 28)
                    .background((simpleMode ? Color.kfAccentBlue : Color.kfAccentPurple).opacity(0.12))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help(simpleMode ? "Simple mode – tap to switch to Advanced" : "Advanced mode – tap to switch to Simple")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Connection

    private var connectionSection: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(vpn.status.swiftUIColor)
                    .frame(width: 8, height: 8)
                Text(vpn.status.label)
                    .font(KFFont.heading(13))
                    .foregroundStyle(vpn.status.swiftUIColor)
                    .animation(.easeInOut(duration: 0.3), value: vpn.status)
                if vpn.status == .connected, let ip = vpn.exitIP ?? vpn.assignedIP {
                    Text("·")
                        .foregroundStyle(Color.kfTextMuted)
                    Text(ip)
                        .font(KFFont.mono(11))
                        .foregroundStyle(Color.kfTextMuted)
                }
                Spacer()
                if vpn.status == .connected, let since = vpn.connectedSince {
                    Text(since, style: .timer)
                        .font(KFFont.mono(11))
                        .foregroundStyle(Color.kfTextMuted)
                        .monospacedDigit()
                }
            }

            Button(action: handleConnectTap) {
                HStack {
                    Spacer()
                    if vpn.status == .connecting || vpn.status == .disconnecting {
                        KataProgressRing()
                            .scaleEffect(0.7)
                            .tint(.white)
                    }
                    Text(connectButtonLabel)
                        .font(KFFont.caption(12, weight: .bold))
                        .kerning(1.2)
                    Spacer()
                }
                .frame(height: 32)
                .background(connectButtonColor)
                .clipShape(RoundedRectangle(cornerRadius: KFRadius.sm, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(vpn.status == .connecting || vpn.status == .disconnecting)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Server

    private var serverSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    if !simpleMode {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showServerList.toggle()
                        }
                        if !showServerList {
                            Task { await servers.refresh() }
                        }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: simpleMode ? "sparkles" : "location.north.line.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.kfAccentBlue)
                            .frame(width: 24, height: 24)
                            .background(Color.kfAccentBlue.opacity(0.12))
                            .clipShape(Circle())

                        VStack(alignment: .leading, spacing: 1) {
                            Text("SERVER")
                                .font(KFFont.caption(9, weight: .bold))
                                .kerning(1.2)
                                .foregroundStyle(Color.kfTextMuted)
                            Text(serverDisplayName)
                                .font(KFFont.body(13))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                        }

                        Spacer()

                        if !simpleMode {
                            Image(systemName: showServerList ? "chevron.up" : "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color.kfTextMuted)
                        }
                    }
                }
                .buttonStyle(.plain)

                if !simpleMode {
                    // Compact region label tap
                    Button {
                        showRegionPicker = true
                    } label: {
                        HStack(spacing: 3) {
                            Text(currentRegionShort)
                                .font(KFFont.caption(10))
                                .foregroundStyle(Color.kfAccentBlue)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8))
                                .foregroundStyle(Color.kfAccentBlue)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)

            if showServerList && !simpleMode {
                serverListView
            }
        }
    }

    private var serverListView: some View {
        VStack(spacing: 0) {
            Divider()
                .background(Color.kfBorder)
                .padding(.horizontal, 14)

            if servers.isLoading && servers.servers.isEmpty {
                HStack {
                    Spacer()
                    KataProgressRing()
                        .scaleEffect(0.7)
                    Spacer()
                }
                .padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(servers.servers) { entry in
                            serverRow(entry: entry)
                        }
                    }
                }
                .frame(maxHeight: 180)
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
            HStack(spacing: 10) {
                Text(entry.server.flagEmoji)
                    .font(.system(size: 16))
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.server.cityName)
                        .font(KFFont.body(12))
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
                    Text("—")
                        .font(KFFont.mono(10))
                        .foregroundStyle(Color.kfTextMuted)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(isSelected ? Color.kfAccentBlue.opacity(0.08) : Color.clear)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Advanced compact (kill switch + multi-hop + stay connected)

    private var advancedCompactSection: some View {
        VStack(spacing: 0) {
            // Kill switch
            HStack(spacing: 10) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.kfAccentPurple)
                    .frame(width: 20, height: 20)
                Text("Kill Switch")
                    .font(KFFont.body(12))
                    .foregroundStyle(.white)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { vpn.tunnelMode == .full },
                    set: { on in Task { await vpn.setTunnelMode(on ? .full : .standard) } }
                ))
                .toggleStyle(.switch)
                .scaleEffect(0.7)
                .tint(Color.kfAccentPurple)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)

            Divider().background(Color.kfBorder).padding(.horizontal, 14)

            // Multi-hop
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(hex: "#f59e0b"))
                    .frame(width: 20, height: 20)
                Text("Multi-Hop")
                    .font(KFFont.body(12))
                    .foregroundStyle(storeKit.hasMultiHop ? .white : Color.kfTextMuted)
                Spacer()
                Toggle("", isOn: $multiHopEnabled)
                    .toggleStyle(.switch)
                    .scaleEffect(0.7)
                    .tint(Color(hex: "#f59e0b"))
                    .disabled(!storeKit.hasMultiHop)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)

            Divider().background(Color.kfBorder).padding(.horizontal, 14)

            // Stay connected
            HStack(spacing: 10) {
                Image(systemName: "wifi")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.kfConnected)
                    .frame(width: 20, height: 20)
                Text("Stay Connected")
                    .font(KFFont.body(12))
                    .foregroundStyle(.white)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { vpn.autoConnectEnabled },
                    set: { on in Task { await vpn.setAutoConnect(on) } }
                ))
                .toggleStyle(.switch)
                .scaleEffect(0.7)
                .tint(Color.kfConnected)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
        }
    }

    // MARK: - Haven DNS

    private var havenSection: some View {
        HStack(spacing: 10) {
            Image(systemName: haven.isEnabled ? "shield.checkered" : "shield.slash")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(haven.isEnabled ? Color.kfConnected : Color.kfTextMuted)
                .frame(width: 24, height: 24)
                .background((haven.isEnabled ? Color.kfConnected : Color.kfTextMuted).opacity(0.12))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text("HAVEN DNS")
                    .font(KFFont.caption(9, weight: .bold))
                    .kerning(1.2)
                    .foregroundStyle(Color.kfTextMuted)
                Text(haven.isEnabled ? "Ad & tracker blocking active" : "Protection off")
                    .font(KFFont.body(12))
                    .foregroundStyle(.white)
            }

            Spacer()

            if haven.isLoading {
                KataProgressRing()
                    .scaleEffect(0.7)
            } else {
                Toggle("", isOn: Binding(
                    get: { haven.isEnabled },
                    set: { _ in Task { await haven.toggle() } }
                ))
                .toggleStyle(.switch)
                .scaleEffect(0.75)
                .tint(Color.kfConnected)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    // MARK: - Account

    private var accountSection: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.kfAccentPurple)
                .frame(width: 24, height: 24)
                .background(Color.kfAccentPurple.opacity(0.12))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(storeKit.subscription?.planDisplayName ?? "No Plan")
                    .font(KFFont.body(12))
                    .foregroundStyle(.white)
                if let sub = storeKit.subscription {
                    Text("Expires \(sub.expiryFormatted)")
                        .font(KFFont.caption(10))
                        .foregroundStyle(Color.kfTextMuted)
                } else {
                    Text("Tap to activate")
                        .font(KFFont.caption(10))
                        .foregroundStyle(Color.kfAccentBlue)
                }
            }

            Spacer()

            Button("Manage") {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            }
            .font(KFFont.caption(11))
            .buttonStyle(.plain)
            .foregroundStyle(Color.kfAccentBlue)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Button("Open") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            .buttonStyle(.plain)
            .font(KFFont.caption(11))
            .foregroundStyle(Color.kfTextMuted)

            Button("Settings") {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            }
            .buttonStyle(.plain)
            .font(KFFont.caption(11))
            .foregroundStyle(Color.kfTextMuted)

            Spacer()

            Button("Quit") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(KFFont.caption(11))
            .foregroundStyle(Color.kfTextMuted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Connect action

    private func handleConnectTap() {
        guard storeKit.hasVPN else {
            upgradeReason = .vpnRequiresEnclave
            showUpgradeSheet = true
            return
        }

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

    // MARK: - Computed helpers

    private var currentRegionShort: String {
        if let region = vpn.connectedServer?.region {
            switch region {
            case "us-east":      return "US-E ▾"
            case "us-west":      return "US-W ▾"
            case "eu-west":      return "EU-W ▾"
            case "eu-north":     return "EU-N ▾"
            case "ap-southeast": return "SEA ▾"
            case "ap-northeast": return "JP ▾"
            case "ap-south":     return "IN ▾"
            default:             return "\(region) ▾"
            }
        }
        return "Auto ▾"
    }

    private var serverDisplayName: String {
        if simpleMode {
            return vpn.connectedServer?.cityName ?? "Nearest · GeoIP"
        }
        return servers.selectedServer?.cityName ?? "Select a server"
    }

    private var connectButtonLabel: String {
        switch vpn.status {
        case .connected:      return "DISCONNECT"
        case .connecting:     return "CONNECTING"
        case .disconnecting:  return "DISCONNECTING"
        default:              return "CONNECT"
        }
    }

    private var connectButtonColor: Color {
        switch vpn.status {
        case .connected:                    return Color.kfError.opacity(0.85)
        case .connecting, .disconnecting:   return Color.kfConnecting.opacity(0.85)
        default:                            return Color.kfAccentBlue
        }
    }

    private var statusGlowColor: Color {
        switch vpn.status {
        case .connected:                    return .kfConnected
        case .connecting, .disconnecting:   return .kfConnecting
        default:                            return .kfAccentBlue
        }
    }

    private var statusIconColor: Color {
        switch vpn.status {
        case .connected:                    return .kfConnected
        case .connecting, .disconnecting:   return .kfConnecting
        default:                            return Color.kfTextMuted
        }
    }
}
