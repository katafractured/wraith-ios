// MultiHopPickerSheet.swift
// WraithVPN
//
// Enclave+ feature: double-tunnel picker.
// Default mode auto-selects the two lowest-latency nodes from different regions.
// Manual mode lets the user pick entry and exit nodes separately.
//
// Traffic path: device → entry node → exit node → internet.
// Entry node sees the client's identity; exit node sees only encrypted traffic
// from the entry node — neither hop alone can correlate identity and activity.

import SwiftUI
import KatafractStyle

struct MultiHopPickerSheet: View {

    @EnvironmentObject var vpn:     WireGuardManager
    @EnvironmentObject var servers: ServerListManager
    @Environment(\.dismiss) private var dismiss

    @State private var autoMode    = true
    @State private var entryServer: VPNServer? = nil
    @State private var exitServer:  VPNServer? = nil
    @State private var pickingRole: HopRole? = nil
    @State private var isConnecting = false
    @State private var errorMessage: String? = nil

    enum HopRole: String, Identifiable {
        case entry, exit
        var id: String { rawValue }
    }

    // MARK: - Auto-select

    /// Two lowest-latency nodes from different regions for auto mode.
    private var autoSelection: (entry: VPNServer, exit: VPNServer)? {
        let ranked = servers.servers
            .filter { $0.milliseconds != nil }
            .sorted { ($0.milliseconds ?? Double.infinity) < ($1.milliseconds ?? Double.infinity) }
            .map(\.server)

        // Also include un-probed servers ranked by load score as fallback
        let all = ranked + servers.servers
            .filter { $0.milliseconds == nil }
            .sorted { $0.server.loadScore < $1.server.loadScore }
            .map(\.server)

        guard all.count >= 2 else { return nil }
        let first = all[0]
        // Prefer a different region for geographic separation, but fall back to any
        // different node so auto-mode always yields a valid pair when 2+ nodes exist.
        let second = all.first(where: { $0.region != first.region })
                  ?? all.first(where: { $0.nodeId != first.nodeId })
        guard let second else { return nil }
        return (entry: first, exit: second)
    }

    private var resolvedEntry: VPNServer? {
        autoMode ? autoSelection?.entry : entryServer
    }
    private var resolvedExit: VPNServer? {
        autoMode ? autoSelection?.exit : exitServer
    }

    private var canConnect: Bool {
        guard let e = resolvedEntry, let x = resolvedExit else { return false }
        return e.nodeId != x.nodeId
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                Color(hex: "#0d0f14").ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: KFSpacing.xl) {
                        headerSection
                        modeToggle
                        routeCards
                        if let err = errorMessage {
                            Text(err)
                                .font(KFFont.body(14))
                                .foregroundStyle(Color.red.opacity(0.85))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, KFSpacing.lg)
                        }
                        connectButton
                    }
                    .padding(.horizontal, KFSpacing.lg)
                    .padding(.vertical, KFSpacing.lg)
                }
            }
            .navigationTitle("Multi-Hop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Color.kfTextMuted)
                }
            }
            .toolbarBackground(Color(hex: "#0d0f14"), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .preferredColorScheme(.dark)
        }
        .sheet(item: $pickingRole) { role in
            serverPickerSheet(for: role)
        }
        .task {
            if servers.servers.isEmpty { await servers.refresh() }
        }
    }

    // MARK: - Sub-views

    private var headerSection: some View {
        VStack(spacing: KFSpacing.sm) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(Color(hex: "#f59e0b"))

            Text("Double-Hop Routing")
                .font(KFFont.heading(20))
                .foregroundStyle(.white)

            Text("Your traffic is encrypted twice and routed through two separate nodes. Neither hop can see both your identity and your activity.")
                .font(KFFont.body(14))
                .foregroundStyle(Color.kfTextSecondary)
                .multilineTextAlignment(.center)
        }
    }

    private var modeToggle: some View {
        HStack(spacing: 0) {
            modeTab(label: "Auto", selected: autoMode) { autoMode = true }
            modeTab(label: "Manual", selected: !autoMode) { autoMode = false }
        }
        .background(Color.kfSurface)
        .clipShape(RoundedRectangle(cornerRadius: KFRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: KFRadius.md)
                .stroke(Color.kfBorder, lineWidth: 1)
        )
    }

    private func modeTab(label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 15, weight: selected ? .semibold : .regular, design: .rounded))
                .foregroundStyle(selected ? .white : Color.kfTextMuted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    selected
                        ? Color(hex: "#f59e0b").opacity(0.2)
                        : Color.clear
                )
                .clipShape(RoundedRectangle(cornerRadius: KFRadius.md - 1))
        }
    }

    private var routeCards: some View {
        VStack(spacing: KFSpacing.sm) {
            hopCard(
                role: "ENTRY NODE",
                subtitle: "Your traffic enters here",
                icon: "arrow.up.circle.fill",
                server: resolvedEntry,
                tappable: !autoMode
            ) { pickingRole = .entry }

            // Arrow indicator
            Image(systemName: "arrow.down")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.kfTextMuted)
                .frame(maxWidth: .infinity, alignment: .center)

            hopCard(
                role: "EXIT NODE",
                subtitle: "Traffic exits to the internet here",
                icon: "arrow.down.circle.fill",
                server: resolvedExit,
                tappable: !autoMode
            ) { pickingRole = .exit }

            if let e = resolvedEntry, let x = resolvedExit, e.nodeId == x.nodeId {
                Text("Entry and exit must be different nodes.")
                    .font(KFFont.caption(13))
                    .foregroundStyle(Color.red.opacity(0.8))
                    .padding(.top, 4)
            }
        }
    }

    private func hopCard(
        role: String,
        subtitle: String,
        icon: String,
        server: VPNServer?,
        tappable: Bool,
        onTap: @escaping () -> Void
    ) -> some View {
        Button(action: { if tappable { onTap() } }) {
            HStack(spacing: KFSpacing.md) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundStyle(Color(hex: "#f59e0b"))
                    .frame(width: 44, height: 44)
                    .background(Color(hex: "#f59e0b").opacity(0.12))
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(role)
                        .font(KFFont.caption(11, weight: .bold))
                        .kerning(1.2)
                        .foregroundStyle(Color.kfTextMuted)
                    if let server {
                        HStack(spacing: 6) {
                            Text(server.flagEmoji)
                                .font(.system(size: 16))
                            Text(server.cityName)
                                .font(KFFont.heading(16))
                                .foregroundStyle(.white)
                        }
                        Text(subtitle)
                            .font(KFFont.caption(12))
                            .foregroundStyle(Color.kfTextMuted)
                    } else {
                        Text(autoMode ? "Selecting fastest…" : "Tap to choose")
                            .font(KFFont.body(15))
                            .foregroundStyle(Color.kfTextSecondary)
                        Text(subtitle)
                            .font(KFFont.caption(12))
                            .foregroundStyle(Color.kfTextMuted)
                    }
                }

                Spacer()

                if tappable {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.kfTextMuted)
                }
            }
            .padding(KFSpacing.md)
            .background(Color.kfSurface)
            .clipShape(RoundedRectangle(cornerRadius: KFRadius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: KFRadius.md, style: .continuous)
                    .stroke(Color.kfBorder, lineWidth: 1)
            )
        }
        .disabled(!tappable)
    }

    private var connectButton: some View {
        Button {
            guard let entry = resolvedEntry, let exit = resolvedExit else { return }
            isConnecting = true
            errorMessage = nil
            Task {
                defer { isConnecting = false }
                do {
                    try await vpn.connectMultiHop(entry: entry, exit: exit)
                    dismiss()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        } label: {
            HStack(spacing: KFSpacing.sm) {
                if isConnecting {
                    KataProgressRing()
                        .tint(.white)
                        .scaleEffect(0.85)
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 15, weight: .semibold))
                }
                Text(isConnecting ? "Connecting…" : "Connect Multi-Hop")
                    .font(KFFont.caption(16, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(canConnect && !isConnecting ? Color(hex: "#f59e0b") : Color(hex: "#f59e0b").opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .disabled(!canConnect || isConnecting)
    }

    // MARK: - Node picker sheet

    private func serverPickerSheet(for role: HopRole) -> some View {
        NavigationStack {
            ZStack {
                Color.kfBackground.ignoresSafeArea()
                serverList(for: role)
            }
            .navigationTitle(role == .entry ? "Entry Node" : "Exit Node")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") { pickingRole = nil }
                        .foregroundStyle(Color.kfAccentBlue)
                }
            }
            .toolbarBackground(Color.kfBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .preferredColorScheme(.dark)
        }
    }

    private func serverList(for role: HopRole) -> some View {
        let opposite: VPNServer? = role == .entry ? exitServer : entryServer

        // Group servers by region
        let grouped = Dictionary(grouping: servers.servers, by: { $0.server.region })
        let sortedRegions = grouped.keys.sorted { r1, r2 in
            // Sort regions by best ping in each, or load if tied
            let bestPing1 = grouped[r1]?.compactMap(\.milliseconds).min() ?? Double.infinity
            let bestPing2 = grouped[r2]?.compactMap(\.milliseconds).min() ?? Double.infinity
            if abs(bestPing1 - bestPing2) < 5 {
                let load1 = grouped[r1]?.map { Double($0.server.loadScore) }.min() ?? Double.infinity
                let load2 = grouped[r2]?.map { Double($0.server.loadScore) }.min() ?? Double.infinity
                return load1 < load2
            }
            return bestPing1 < bestPing2
        }

        return ScrollView(showsIndicators: false) {
            LazyVStack(spacing: KFSpacing.sm) {
                ForEach(sortedRegions, id: \.self) { region in
                    regionGroup(region: region, opposite: opposite, for: role)
                }
            }
            .padding(.horizontal, KFSpacing.md)
            .padding(.vertical, KFSpacing.sm)
        }
    }

    private func regionGroup(region: String, opposite: VPNServer?, for role: HopRole) -> some View {
        let regionServers = servers.servers
            .filter { $0.server.region == region }
            .sorted {
                switch ($0.milliseconds, $1.milliseconds) {
                case (let a?, let b?): return a < b
                case (.some, nil):     return true
                case (nil, .some):     return false
                case (nil, nil):       return $0.server.loadScore < $1.server.loadScore
                }
            }

        let bestPing = regionServers.compactMap(\.milliseconds).min()

        return VStack(spacing: 0) {
            DisclosureGroup {
                LazyVStack(spacing: KFSpacing.xs) {
                    ForEach(regionServers) { item in
                        let isOpposite = item.server.nodeId == opposite?.nodeId
                        Button {
                            if role == .entry { entryServer = item.server }
                            else { exitServer = item.server }
                            pickingRole = nil
                        } label: {
                            HStack(spacing: KFSpacing.md) {
                                Text(item.server.flagEmoji)
                                    .font(.system(size: 22))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.server.cityName)
                                        .font(KFFont.heading(15))
                                        .foregroundStyle(isOpposite ? Color.kfTextMuted : .white)
                                    if isOpposite {
                                        Text("Already selected as \(role == .entry ? "exit" : "entry")")
                                            .font(KFFont.caption(12))
                                            .foregroundStyle(Color.kfTextMuted)
                                    }
                                }
                                Spacer()
                                if let ms = item.milliseconds {
                                    Text("\(Int(ms)) ms")
                                        .font(KFFont.mono(12))
                                        .foregroundStyle(latencyColor(ms))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(latencyColor(ms).opacity(0.12))
                                        .clipShape(Capsule())
                                } else {
                                    Text("—")
                                        .font(KFFont.mono(12))
                                        .foregroundStyle(Color.kfTextMuted)
                                }
                            }
                            .padding(KFSpacing.md)
                            .background(Color.kfSurface)
                            .clipShape(RoundedRectangle(cornerRadius: KFRadius.md, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: KFRadius.md, style: .continuous)
                                    .stroke(isOpposite ? Color.kfBorder.opacity(0.4) : Color.kfBorder, lineWidth: 1)
                            )
                            .opacity(isOpposite ? 0.5 : 1)
                        }
                        .disabled(isOpposite)
                    }
                }
                .padding(.vertical, KFSpacing.xs)
            } label: {
                regionLabel(region, bestPing: bestPing)
            }
            .tint(.white)
        }
    }

    private func regionLabel(_ regionId: String, bestPing: Double?) -> some View {
        HStack(spacing: KFSpacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(regionLabelForId(regionId))
                    .font(KFFont.heading(15))
                    .foregroundStyle(.white)
            }
            Spacer()
            if let ping = bestPing {
                Text("\(Int(ping)) ms")
                    .font(KFFont.mono(13))
                    .foregroundStyle(latencyColor(ping))
            }
        }
        .padding(KFSpacing.md)
        .background(Color.kfSurface.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: KFRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: KFRadius.md, style: .continuous)
                .stroke(Color.kfBorder, lineWidth: 1)
        )
    }

    private func regionLabelForId(_ regionId: String) -> String {
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

    private func latencyColor(_ ms: Double) -> Color {
        switch ms {
        case ..<80:  return Color(hex: "#22c55e")
        case ..<180: return Color(hex: "#f59e0b")
        default:     return Color(hex: "#ef4444")
        }
    }
}

