// ServerPickerView.swift
// WraithVPN
//
// Full-screen server list sorted by latency. Shows city name + flag, latency
// badge, and load indicator. Technical details (IPs, node IDs) are hidden.

import SwiftUI
import KatafractStyle

struct ServerPickerView: View {

    @EnvironmentObject var servers: ServerListManager
    @EnvironmentObject var vpn:     WireGuardManager
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""
    @State private var sortByLatency = true

    // MARK: - Filtered / sorted list

    private var displayedServers: [ServerLatency] {
        var list = servers.servers

        if !searchText.isEmpty {
            list = list.filter {
                $0.server.cityName.localizedCaseInsensitiveContains(searchText) ||
                $0.server.region.localizedCaseInsensitiveContains(searchText)
            }
        }

        if sortByLatency {
            list = list.sorted {
                switch ($0.milliseconds, $1.milliseconds) {
                case (let a?, let b?): return a < b
                case (.some, nil):     return true
                case (nil, .some):     return false
                case (nil, nil):       return false
                }
            }
        } else {
            list = list.sorted { $0.server.cityName < $1.server.cityName }
        }
        return list
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                Color.kfBackground.ignoresSafeArea()

                VStack(spacing: KFSpacing.md) {
                    topPanel

                    if servers.isLoading && servers.servers.isEmpty {
                        loadingState
                    } else if displayedServers.isEmpty {
                        emptyState
                    } else {
                        serverList
                    }
                }
            }
            .navigationTitle("Choose Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Color.kfAccentBlue)
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    if servers.isLoading {
                        KataProgressRing()
                            .tint(Color.kfAccentBlue)
                    }
                }
            }
            .toolbarBackground(Color.kfBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .preferredColorScheme(.dark)
            .task {
                if servers.servers.isEmpty {
                    await servers.refresh()
                }
            }
        }
    }

    // MARK: - Sub-views

    private var topPanel: some View {
        VStack(spacing: KFSpacing.sm) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("WRAITHGATES")
                        .font(KFFont.caption(11, weight: .bold))
                        .kerning(1.5)
                        .foregroundStyle(Color.kfTextMuted)
                    Text("Choose Your Route")
                        .font(KFFont.heading(22))
                        .foregroundStyle(.white)
                }
                Spacer()
                Text("\(displayedServers.count)")
                    .font(KFFont.heading(16))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.kfSurfaceElevated)
                    .clipShape(Capsule())
            }

            searchBar
                .padding(0)

            sortToggle
        }
        .padding(KFSpacing.md)
        .background(Color.kfSurface.opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: KFRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: KFRadius.lg, style: .continuous)
                .stroke(Color.kfBorder, lineWidth: 1)
        )
        .padding(.horizontal, KFSpacing.md)
        .padding(.top, KFSpacing.sm)
    }

    private var searchBar: some View {
        HStack(spacing: KFSpacing.xs) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.kfTextMuted)
            TextField("Search cities…", text: $searchText)
                .foregroundStyle(Color.kfTextPrimary)
                .tint(Color.kfAccentBlue)
        }
        .padding(KFSpacing.sm)
        .background(Color.kfSurfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: KFRadius.md))
    }

    private var sortToggle: some View {
        HStack {
            Text("Sort by")
                .font(KFFont.caption(13))
                .foregroundStyle(Color.kfTextMuted)
            Spacer()
            Picker("Sort", selection: $sortByLatency) {
                Text("Latency").tag(true)
                Text("Name").tag(false)
            }
            .pickerStyle(.segmented)
            .frame(width: 160)
        }
    }

    private var serverList: some View {
        ScrollView {
            // Pull-to-refresh hint banner when VPN is connected

            LazyVStack(spacing: KFSpacing.xs) {
                ForEach(displayedServers) { item in
                    ServerRowView(
                        item: item,
                        isSelected: servers.selectedServer?.nodeId == item.server.nodeId
                    )
                    .onTapGesture {
                        selectServer(item.server)
                    }
                }
            }
            .padding(.horizontal, KFSpacing.md)
            .padding(.bottom, KFSpacing.lg)
        }
        .refreshable {
            await servers.refresh()
        }
    }

    private var loadingState: some View {
        VStack(spacing: KFSpacing.lg) {
            Spacer()
            KataProgressRing()
                .tint(Color.kfAccentBlue)
                .scaleEffect(1.4)
            Text("Loading servers…")
                .font(KFFont.body())
                .foregroundStyle(Color.kfTextMuted)
            Spacer()
        }
    }

    private var emptyState: some View {
        VStack(spacing: KFSpacing.md) {
            Spacer()
            Image(systemName: "server.rack")
                .font(.system(size: 48))
                .foregroundStyle(Color.kfTextMuted)
            Text("No servers found")
                .font(KFFont.heading())
                .foregroundStyle(Color.kfTextSecondary)
            Spacer()
        }
    }

    // MARK: - Actions

    private func selectServer(_ server: VPNServer) {
        servers.selectServer(server)
        let gen = UIImpactFeedbackGenerator(style: .medium)
        gen.impactOccurred()

        // If already connected to a different node, switch immediately.
        let isConnected = vpn.status == .connected || vpn.status == .connecting
        let isDifferent = vpn.connectedServer?.nodeId != server.nodeId
        if isConnected && isDifferent {
            Task {
                try? await vpn.connectToServer(server)
            }
        }

        dismiss()
    }
}

// MARK: - Server row

private struct ServerRowView: View {
    let item: ServerLatency
    let isSelected: Bool

    var body: some View {
        HStack(spacing: KFSpacing.md) {
            Text(item.server.flagEmoji)
                .font(.system(size: 26))
                .frame(width: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.server.cityName)
                    .font(KFFont.heading(16))
                    .foregroundStyle(Color.kfTextPrimary)
                Text(regionLabel)
                    .font(KFFont.caption(12))
                    .foregroundStyle(Color.kfTextMuted)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 8) {
                latencyBadge
                LoadBar(score: item.server.loadScore)
            }
        }
        .padding(KFSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: KFRadius.md, style: .continuous)
                .fill(isSelected ? Color.kfAccentBlue.opacity(0.12) : Color.kfSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: KFRadius.md, style: .continuous)
                .strokeBorder(
                    isSelected ? Color.kfAccentBlue.opacity(0.5) : Color.kfBorder,
                    lineWidth: 1
                )
        )
        .animation(.easeInOut(duration: 0.2), value: isSelected)
    }

    private var latencyBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(item.latencyTier.swiftUIColor)
                .frame(width: 7, height: 7)
            Text(item.displayLatency)
                .font(KFFont.mono(12))
                .foregroundStyle(item.latencyTier.swiftUIColor)
        }
        .padding(.horizontal, KFSpacing.xs)
        .padding(.vertical, 4)
        .background(item.latencyTier.swiftUIColor.opacity(0.12))
        .clipShape(Capsule())
    }

    private var regionLabel: String {
        item.server.region
    }
}

// MARK: - Load bar

private struct LoadBar: View {
    let score: Double   // 0.0 – 1.0

    private var color: Color {
        switch score {
        case ..<0.5: return .kfLatencyExcellent
        case ..<0.75: return .kfLatencyFair
        default:      return .kfLatencyPoor
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.kfBorder)
                RoundedRectangle(cornerRadius: 3)
                    .fill(color)
                    .frame(width: geo.size.width * CGFloat(score))
            }
        }
        .frame(width: 52, height: 6)
    }
}

// MARK: - Preview

#Preview {
    ServerPickerView()
        .environmentObject(ServerListManager())
        .environmentObject(WireGuardManager())
}
