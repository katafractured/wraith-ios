// MacRegionPickerView.swift
// WraithVPNMac
//
// macOS port of RegionPickerView. List-based, native Mac style.

import SwiftUI
import KatafractStyle

struct MacRegionPickerView: View {

    @EnvironmentObject var vpn:     WireGuardManager
    @EnvironmentObject var servers: ServerListManager
    @Environment(\.dismiss) private var dismiss

    @State private var regions: [RegionSummary] = []
    @State private var isLoading = false
    @State private var errorMessage: String? = nil
    @State private var connecting: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Choose Region")
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

            if isLoading && regions.isEmpty {
                HStack { Spacer(); KataProgressRing(); Spacer() }
                    .padding(24)
            } else if let msg = errorMessage, regions.isEmpty {
                VStack(spacing: 12) {
                    Text(msg).font(KFFont.caption(12)).foregroundStyle(Color.kfTextMuted)
                    Button("Retry") { Task { await loadRegions() } }.foregroundStyle(Color.kfAccentBlue)
                }
                .padding(24)
            } else {
                List {
                    // Auto row
                    Button {
                        Task { await connectTo("auto") }
                    } label: {
                        HStack(spacing: 12) {
                            Text("🌐").font(.system(size: 22))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Auto (Best Available)")
                                    .font(KFFont.body(14))
                                    .foregroundStyle(.white)
                                Text("GeoIP + latency selection")
                                    .font(KFFont.caption(11))
                                    .foregroundStyle(Color.kfTextMuted)
                            }
                            Spacer()
                            if connecting == "auto" {
                                KataProgressRing(size: 20)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.kfSurface)

                    ForEach(sortedRegions) { region in
                        let bestPing = bestPingMs(for: region)
                        Button {
                            Task { await connectTo(region.id) }
                        } label: {
                            HStack(spacing: 12) {
                                Text(continentFlag(region.continent))
                                    .font(.system(size: 22))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(region.label)
                                        .font(KFFont.body(14))
                                        .foregroundStyle(.white)
                                    Text(region.healthyNodeCount == 1 ? "1 server" : "\(region.healthyNodeCount) servers")
                                        .font(KFFont.caption(11))
                                        .foregroundStyle(Color.kfTextMuted)
                                }
                                Spacer()
                                if let ping = bestPing {
                                    Text("\(Int(ping)) ms")
                                        .font(KFFont.mono(12))
                                        .foregroundStyle(pingColor(ping))
                                }
                                if connecting == region.id {
                                    KataProgressRing(size: 20)
                                } else if vpn.connectedServer?.region == region.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color.kfAccentBlue)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.kfSurface)
                        .disabled(connecting != nil)
                    }
                }
                .listStyle(.plain)
                .background(Color.kfBackground)
            }

            if let msg = errorMessage, !regions.isEmpty {
                Text(msg)
                    .font(KFFont.caption(11))
                    .foregroundStyle(Color.kfError)
                    .padding(8)
            }
        }
        .frame(width: 360)
        .frame(minHeight: 320)
        .background(Color.kfBackground)
        .preferredColorScheme(.dark)
        .task { await loadRegions() }
    }

    // MARK: - Logic

    private var sortedRegions: [RegionSummary] {
        regions.sorted { a, b in
            let pingA = bestPingMs(for: a) ?? Double.infinity
            let pingB = bestPingMs(for: b) ?? Double.infinity
            if pingA < Double.infinity && pingB < Double.infinity && abs(pingA - pingB) < 5 {
                return a.avgLoadScore < b.avgLoadScore
            }
            if pingA != pingB { return pingA < pingB }
            return a.label < b.label
        }
    }

    private func bestPingMs(for region: RegionSummary) -> Double? {
        servers.servers
            .filter { $0.server.region == region.id && $0.milliseconds != nil }
            .min { ($0.milliseconds ?? Double.infinity) < ($1.milliseconds ?? Double.infinity) }?
            .milliseconds
    }

    private func pingColor(_ ms: Double) -> Color {
        switch ms {
        case ..<80:  return Color(hex: "#22c55e")
        case ..<180: return Color(hex: "#f59e0b")
        default:     return Color(hex: "#ef4444")
        }
    }

    private func continentFlag(_ continent: String) -> String {
        switch continent {
        case "NA", "SA": return "🌎"
        case "EU", "AF": return "🌍"
        case "AS", "OC": return "🌏"
        default:         return "🌐"
        }
    }

    private func loadRegions() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do { regions = try await APIClient.shared.fetchRegions() }
        catch { errorMessage = "Could not load regions" }
    }

    private func connectTo(_ regionId: String) async {
        connecting = regionId
        defer { connecting = nil }
        do {
            try await vpn.connectToRegion(regionId)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
