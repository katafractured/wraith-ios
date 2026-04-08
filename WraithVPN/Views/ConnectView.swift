// ConnectView.swift
// WraithVPN
//
// Main screen: animated connect button, status label, selected server location,
// current assigned IP when connected, and quick-access to server picker.

import SwiftUI

struct ConnectView: View {

    @EnvironmentObject var vpn:    WireGuardManager
    @EnvironmentObject var servers: ServerListManager

    @AppStorage("simpleMode") private var simpleMode = true

    @State private var showServerPicker = false
    @State private var isAnimatingRing  = false
    @State private var errorMessage: String? = nil
    @State private var showError = false

    // MARK: - Body

    var body: some View {
        GeometryReader { proxy in
            let layout = ConnectLayout(proxy: proxy)

            ZStack {
                backgroundGradient
                    .ignoresSafeArea()

                VStack(spacing: layout.sectionSpacing) {
                    header
                    heroSection(layout: layout)
                    connectionSummary
                    serverButton
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, KFSpacing.lg)
                .padding(.top, layout.topPadding)
                .padding(.bottom, layout.bottomPadding)
            }
        }
        .sheet(isPresented: $showServerPicker) {
            ServerPickerView()
                .environmentObject(servers)
                .environmentObject(vpn)
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
        }
        // When the connected node changes (switch, provision, restore), keep the
        // picker's selectedServer in sync so the UI never shows the wrong location.
        .onChange(of: vpn.connectedServer?.nodeId) { _, _ in
            syncSelectedToConnected()
        }
    }

    // MARK: - Helpers

    /// Sets `servers.selectedServer` to the full server object whose nodeId matches
    /// `vpn.connectedServer`. Falls back to leaving the selection unchanged if the
    /// connected node isn't in the server list yet (e.g. list hasn't loaded).
    private func syncSelectedToConnected() {
        guard let nodeId = vpn.connectedServer?.nodeId else { return }
        if let match = servers.servers.first(where: { $0.server.nodeId == nodeId }) {
            servers.selectedServer = match.server
        }
    }

    // MARK: - Sub-views

    private var backgroundGradient: some View {
        ZStack {
            Color.kfBackground
            // Subtle radial glow at top-center
            RadialGradient(
                colors: [
                    vpn.status == .connected
                        ? Color.kfConnected.opacity(0.12)
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
        }
    }

    // MARK: - Connect button

    private var connectButton: some View {
        Button(action: handleConnectTap) {
            ZStack {
                Circle()
                    .stroke(
                        AngularGradient.kfConnectButtonRing(status: vpn.status),
                        lineWidth: 5
                    )
                    .frame(width: 248, height: 248)
                    .rotationEffect(.degrees(isAnimatingRing ? 360 : 0))
                    .animation(
                        vpn.status == .connecting || vpn.status == .disconnecting || vpn.isProvisioning
                            ? .linear(duration: 1.5).repeatForever(autoreverses: false)
                            : .easeOut(duration: 0.5),
                        value: isAnimatingRing
                    )

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                ringCenterColor.opacity(0.25),
                                ringCenterColor.opacity(0.05),
                                Color.clear
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: 112
                        )
                    )
                    .frame(width: 214, height: 214)

                Circle()
                    .fill(Color.kfSurface)
                    .frame(width: 178, height: 178)
                    .overlay(
                        Circle()
                            .strokeBorder(Color.kfBorder, lineWidth: 1)
                            .frame(width: 178, height: 178)
                    )

                VStack(spacing: KFSpacing.xs) {
                    Image(systemName: buttonIcon)
                        .font(.system(size: 42, weight: .medium))
                        .foregroundStyle(
                            vpn.status == .connected
                                ? LinearGradient(colors: [.kfConnected, Color(hex: "#86efac")], startPoint: .top, endPoint: .bottom)
                                : LinearGradient(colors: [.kfTextSecondary, .kfTextMuted], startPoint: .top, endPoint: .bottom)
                        )
                        .animation(.easeInOut(duration: 0.3), value: vpn.status)

                    Text(buttonLabel)
                        .font(KFFont.caption(12, weight: .semibold))
                        .kerning(1.4)
                        .foregroundStyle(Color.kfTextMuted)
                }
            }
        }
        .buttonStyle(ScaleButtonStyle())
        .disabled(vpn.status == .connecting || vpn.status == .disconnecting || vpn.isProvisioning)
        .onChange(of: vpn.status) { _, newStatus in
            isAnimatingRing = (newStatus == .connecting || newStatus == .disconnecting || vpn.isProvisioning)
        }
        .onChange(of: vpn.isProvisioning) { _, provisioning in
            isAnimatingRing = provisioning || vpn.status == .connecting || vpn.status == .disconnecting
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: vpn.status == .connected)
        .sensoryFeedback(.impact(weight: .light),  trigger: vpn.status == .disconnected)
    }

    private func heroSection(layout: ConnectLayout) -> some View {
        VStack(spacing: layout.heroSpacing) {
            connectButton
            statusSection
        }
        .frame(maxWidth: .infinity)
        .padding(.top, layout.heroTopPadding)
    }

    // MARK: - Status section

    private var statusSection: some View {
        VStack(spacing: KFSpacing.xs) {
            Text(vpn.status.label)
                .font(KFFont.heading(24))
                .foregroundStyle(vpn.status.swiftUIColor)
                .animation(.easeInOut(duration: 0.3), value: vpn.status)
                .contentTransition(.numericText())

            if vpn.status == .connected {
                VStack(spacing: 4) {
                    HStack(spacing: KFSpacing.xs) {
                        Image(systemName: "globe")
                            .font(.system(size: 12))
                        Text(vpn.exitIP ?? vpn.assignedIP ?? "—")
                            .font(KFFont.mono(13))
                    }
                    .foregroundStyle(Color.kfTextMuted)
                    if let since = vpn.connectedSince {
                        Text(since, style: .timer)
                            .font(KFFont.mono(12))
                            .foregroundStyle(Color.kfTextMuted.opacity(0.7))
                            .monospacedDigit()
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else {
                Text(statusCaption)
                    .font(KFFont.body(14))
                    .foregroundStyle(Color.kfTextSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: vpn.assignedIP)
    }

    private var connectionSummary: some View {
        VStack(spacing: KFSpacing.sm) {
            HStack(spacing: KFSpacing.md) {
                summaryPill(
                    title: "Route",
                    value: simpleMode ? "Automatic" : (servers.selectedServer?.cityName ?? "Automatic"),
                    icon: (simpleMode || servers.selectedServer == nil) ? "sparkles" : "location.north.line.fill"
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
    }

    // MARK: - Server button

    private var serverButton: some View {
        Button {
            if !simpleMode { showServerPicker = true }
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
        .disabled(simpleMode)
    }

    // MARK: - Actions

    private func handleConnectTap() {
        Task {
            do {
                if vpn.status == .connected {
                    vpn.disconnect()
                    return
                }

                // Haven free tier has no token — VPN requires a subscription.
                if KeychainHelper.shared.readOptional(for: .subscriptionToken) == nil {
                    errorMessage = "WraithVPN requires an active subscription. Upgrade in Settings to get started."
                    showError = true
                    return
                }

                if simpleMode {
                    // Simple mode: always use GeoIP nearest, ignore latency-probe selection.
                    if vpn.isProvisioned {
                        try await vpn.connect()
                    } else {
                        // fetchNearestServer can take up to 15s — set connecting state
                        // immediately so the button responds and shows a spinner.
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

    private var buttonIcon: String {
        if vpn.isProvisioning { return "ellipsis" }
        switch vpn.status {
        case .connected:     return "power"
        case .connecting:    return "ellipsis"
        case .disconnecting: return "ellipsis"
        default:             return "power"
        }
    }

    private var ringCenterColor: Color {
        switch vpn.status {
        case .connected:    return .kfConnected
        case .connecting, .disconnecting: return .kfConnecting
        default:            return .kfAccentPurple
        }
    }

    private var buttonLabel: String {
        if vpn.isProvisioning { return "PREPARING" }
        switch vpn.status {
        case .connected:     return "DISCONNECT"
        case .connecting:    return "CONNECTING"
        case .disconnecting: return "DISCONNECTING"
        default:             return "CONNECT"
        }
    }

    private var statusCaption: String {
        if vpn.isAutoProvisioning {
            return "Setting up your secure route…"
        }
        switch vpn.status {
        case .connected:
            return "Traffic is flowing through the Enclave."
        case .connecting:
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
