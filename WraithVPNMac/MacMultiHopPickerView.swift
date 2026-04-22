// MacMultiHopPickerView.swift
// WraithVPNMac
//
// macOS port of MultiHopPickerSheet. Two-column layout for entry/exit selection.

import SwiftUI
import KatafractStyle

struct MacMultiHopPickerView: View {

    @EnvironmentObject var vpn:     WireGuardManager
    @EnvironmentObject var servers: ServerListManager
    @Environment(\.dismiss) private var dismiss

    @State private var autoMode     = true
    @State private var entryRegion: String? = nil
    @State private var exitRegion:  String? = nil
    @State private var isConnecting = false
    @State private var errorMessage: String? = nil

    // MARK: - Auto selection

    private var autoSelection: (entry: VPNServer, exit: VPNServer)? {
        let ranked = servers.servers
            .filter { $0.milliseconds != nil }
            .sorted { ($0.milliseconds ?? Double.infinity) < ($1.milliseconds ?? Double.infinity) }
            .map(\.server)
        let all = ranked + servers.servers.filter { $0.milliseconds == nil }.map(\.server)
        guard all.count >= 2 else { return nil }
        let first = all[0]
        let second = all.first(where: { $0.region != first.region })
                  ?? all.first(where: { $0.nodeId != first.nodeId })
        guard let second else { return nil }
        return (entry: first, exit: second)
    }

    // Best server for a region
    private func bestServer(for regionId: String) -> VPNServer? {
        servers.servers
            .filter { $0.server.region == regionId }
            .min(by: { ($0.milliseconds ?? Double.infinity) < ($1.milliseconds ?? Double.infinity) })?
            .server
    }

    private var resolvedEntry: VPNServer? {
        autoMode ? autoSelection?.entry : (entryRegion.flatMap { bestServer(for: $0) })
    }
    private var resolvedExit: VPNServer? {
        autoMode ? autoSelection?.exit : (exitRegion.flatMap { bestServer(for: $0) })
    }

    private var canConnect: Bool {
        guard let e = resolvedEntry, let x = resolvedExit else { return false }
        return e.nodeId != x.nodeId
    }

    private var regions: [String] {
        Array(Set(servers.servers.map { $0.server.region })).sorted()
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Multi-Hop Routing")
                    .font(KFFont.heading(16))
                    .foregroundStyle(.white)
                Spacer()
                Button("Cancel") { dismiss() }
                    .foregroundStyle(Color.kfAccentBlue)
                    .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.kfSurface)

            Divider().background(Color.kfBorder)

            VStack(spacing: 16) {
                // Mode toggle
                Picker("Mode", selection: $autoMode) {
                    Text("Auto").tag(true)
                    Text("Manual").tag(false)
                }
                .pickerStyle(.segmented)

                if !autoMode {
                    // Two-column pickers
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("ENTRY NODE")
                                .font(KFFont.caption(10, weight: .bold))
                                .kerning(1.2)
                                .foregroundStyle(Color.kfTextMuted)
                            Picker("Entry", selection: $entryRegion) {
                                Text("Select…").tag(nil as String?)
                                ForEach(regions, id: \.self) { r in
                                    Text(regionLabel(r)).tag(r as String?)
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }

                        Image(systemName: "arrow.right")
                            .foregroundStyle(Color.kfTextMuted)
                            .padding(.top, 20)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("EXIT NODE")
                                .font(KFFont.caption(10, weight: .bold))
                                .kerning(1.2)
                                .foregroundStyle(Color.kfTextMuted)
                            Picker("Exit", selection: $exitRegion) {
                                Text("Select…").tag(nil as String?)
                                ForEach(regions.filter { $0 != entryRegion }, id: \.self) { r in
                                    Text(regionLabel(r)).tag(r as String?)
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                } else {
                    // Auto summary
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Entry")
                                .font(KFFont.caption(11))
                                .foregroundStyle(Color.kfTextMuted)
                            Text(resolvedEntry.map { "\($0.flagEmoji) \($0.cityName)" } ?? "Selecting…")
                                .font(KFFont.body(14))
                                .foregroundStyle(.white)
                        }
                        Image(systemName: "arrow.right")
                            .foregroundStyle(Color.kfTextMuted)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Exit")
                                .font(KFFont.caption(11))
                                .foregroundStyle(Color.kfTextMuted)
                            Text(resolvedExit.map { "\($0.flagEmoji) \($0.cityName)" } ?? "Selecting…")
                                .font(KFFont.body(14))
                                .foregroundStyle(.white)
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background(Color.kfSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                // Warning
                if let e = resolvedEntry, let x = resolvedExit, e.nodeId == x.nodeId {
                    Label("Entry and exit must be in different regions", systemImage: "exclamationmark.triangle")
                        .font(KFFont.caption(12))
                        .foregroundStyle(.kataGold.opacity(0.65))
                }

                if let err = errorMessage {
                    Text(err)
                        .font(KFFont.caption(12))
                        .foregroundStyle(Color.kfError)
                }

                // Connect button
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
                    HStack {
                        Spacer()
                        if isConnecting {
                            KataProgressRing(size: 22)
                        }
                        Text(isConnecting ? "Connecting…" : "Connect Multi-Hop")
                            .font(KFFont.caption(13, weight: .semibold))
                            .foregroundStyle(.white)
                        Spacer()
                    }
                    .frame(height: 36)
                    .background(canConnect && !isConnecting ? Color(hex: "#f59e0b") : Color(hex: "#f59e0b").opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(!canConnect || isConnecting)
            }
            .padding(16)
        }
        .frame(width: 420)
        .background(Color.kfBackground)
        .preferredColorScheme(.dark)
        .task {
            if servers.servers.isEmpty { await servers.refresh() }
        }
    }

    private func regionLabel(_ regionId: String) -> String {
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
}
