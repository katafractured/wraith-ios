// RegionPickerView.swift
// WraithVPN
//
// Phase F — region-first server picker. Sealed-ledger visual treatment.
// No emoji flags — ISO code tile chips. Midnight background, serif names, mono pings.

import SwiftUI
import KatafractStyle

struct RegionPickerView: View {

    @EnvironmentObject var vpn: WireGuardManager
    @EnvironmentObject var servers: ServerListManager
    @Environment(\.dismiss) private var dismiss

    @State private var regions: [RegionSummary] = []
    @State private var isLoading = false
    @State private var errorMessage: String? = nil
    @State private var drillDownRegion: RegionSummary? = nil

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                Color.kataMidnight.ignoresSafeArea()

                VStack(spacing: 0) {
                    if isLoading && regions.isEmpty {
                        loadingState
                    } else if let msg = errorMessage, regions.isEmpty {
                        errorState(msg)
                    } else if regions.isEmpty {
                        emptyState
                    } else {
                        regionList
                    }
                }
            }
            .navigationTitle("Choose Region")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.kataBody(15, weight: .regular))
                        .foregroundStyle(Color.kataChampagne)
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    if isLoading {
                        KataProgressRing()
                    }
                }
            }
            .toolbarBackground(Color.kataMidnight, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .preferredColorScheme(.dark)
            .navigationDestination(item: $drillDownRegion) { region in
                regionDrillDown(region: region)
            }
        }
        .task { await loadRegions() }
    }

    // MARK: - States

    private var loadingState: some View {
        VStack(spacing: 16) {
            KataProgressRing()
            Text("Loading regions…")
                .font(.kataMono(12))
                .foregroundStyle(Color.kataChampagne.opacity(0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            isoChip("?", size: 36)
            Text("No regions available")
                .font(.kataDisplay(18, weight: .regular))
                .foregroundStyle(Color.kataChampagne.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ msg: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundStyle(Color.kataGold)
            Text(msg)
                .font(.kataBody(14))
                .foregroundStyle(Color.kataChampagne.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                Task { await loadRegions() }
            } label: {
                Text("Retry")
                    .font(.kataMono(13, weight: .bold))
                    .foregroundStyle(Color.kataChampagne)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.kataGold.opacity(0.5), lineWidth: 0.5)
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Region list (sealed ledger)

    private var regionList: some View {
        ScrollView {
            VStack(spacing: 0) {
                if shouldShowMeasuringIndicator {
                    Text("Measuring latency…")
                        .font(.kataMono(11))
                        .foregroundStyle(Color.kataChampagne.opacity(0.4))
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                }
                // Auto row
                autoRow
                ledgerDivider

                ForEach(Array(sortedRegions.enumerated()), id: \.element.id) { idx, region in
                    regionRow(region)
                    if idx < sortedRegions.count - 1 {
                        ledgerDivider
                    }
                }
            }
        }
    }

    private var ledgerDivider: some View {
        Rectangle()
            .fill(Color.kataGold.opacity(0.3))
            .frame(height: 0.5)
            .padding(.horizontal, 16)
    }

    // MARK: - Auto row

    private var autoRow: some View {
        let isAuto = vpn.connectedServer == nil || vpn.connectedServer?.region == nil

        return HStack(spacing: 14) {
            // ISO chip for "auto"
            isoChip("AU")

            VStack(alignment: .leading, spacing: 3) {
                Text("Auto (Best Available)")
                    .font(.kataDisplay(20, weight: .medium))
                    .foregroundStyle(Color.kataIce)
                    .lineLimit(1)
                Text("GeoIP + latency selection")
                    .font(.kataMono(11))
                    .foregroundStyle(Color.kataChampagne.opacity(0.5))
            }

            Spacer()

            if isAuto && vpn.status == .connected {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.kataGold)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
        .contentShape(Rectangle())
        .onTapGesture {
            Task { @MainActor in KataHaptic.tap.fire() }
            dismiss()
            Task { try? await vpn.connectToRegion("auto") }
        }
    }

    // MARK: - Region row

    private func regionRow(_ region: RegionSummary) -> some View {
        let bestPing = bestPingMs(for: region)
        let isSelected = vpn.connectedServer?.region == region.id

        return HStack(spacing: 0) {
            // Main tap — connect
            Button {
                Task { @MainActor in KataHaptic.tap.fire() }
                dismiss()
                Task { try? await vpn.connectToRegion(region.id) }
            } label: {
                HStack(spacing: 14) {
                    isoChip(regionISOCode(region))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(region.label)
                            .font(.kataDisplay(20, weight: .medium))
                            .foregroundStyle(Color.kataIce)
                            .lineLimit(1)
                        Text(nodeCountDescription(region))
                            .font(.kataMono(11))
                            .foregroundStyle(Color.kataChampagne.opacity(0.5))
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 4) {
                        if let ping = bestPing {
                            Text("\(Int(ping)) ms")
                                .font(.kataMono(13))
                                .foregroundStyle(Color.kataChampagne)
                        } else {
                            Text("—")
                                .font(.kataMono(13))
                                .foregroundStyle(Color.kataChampagne.opacity(0.35))
                        }
                        loadBadge(score: region.avgLoadScore)
                    }

                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.kataGold)
                            .padding(.leading, 8)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
            }
            .buttonStyle(.plain)

            // Drill-down
            Rectangle()
                .fill(Color.kataGold.opacity(0.3))
                .frame(width: 0.5, height: 28)

            Button {
                drillDownRegion = region
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.kataChampagne.opacity(0.4))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 18)
            }
            .buttonStyle(.plain)
        }
        .contentShape(Rectangle())
    }

    // MARK: - ISO chip helper

    private func isoChip(_ code: String, size: CGFloat = 12) -> some View {
        Text(code)
            .font(.kataMono(size == 12 ? 9 : 11, weight: .bold))
            .foregroundStyle(Color.kataIce)
            .frame(width: size == 12 ? 28 : 42, height: size == 12 ? 28 : 42)
            .background(Color.kataSapphire.opacity(0.6))
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Color.kataGold.opacity(0.4), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    // MARK: - Drill-down destination

    @ViewBuilder
    private func regionDrillDown(region: RegionSummary) -> some View {
        let regionServers = servers.servers.filter { $0.server.region == region.id }
        ZStack {
            Color.kataMidnight.ignoresSafeArea()
            if regionServers.isEmpty {
                VStack(spacing: 16) {
                    if servers.isLoading {
                        KataProgressRing()
                        Text("Loading servers…")
                            .font(.kataMono(12))
                            .foregroundStyle(Color.kataChampagne.opacity(0.5))
                    } else {
                        Text("No servers in this region")
                            .font(.kataDisplay(18, weight: .regular))
                            .foregroundStyle(Color.kataChampagne.opacity(0.6))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(regionServers.sorted {
                            switch ($0.milliseconds, $1.milliseconds) {
                            case (let a?, let b?): return a < b
                            case (.some, nil):     return true
                            default:               return false
                            }
                        }.enumerated()), id: \.element.server.nodeId) { idx, item in
                            Button {
                                servers.selectServer(item.server)
                                dismiss()
                                Task { try? await vpn.connectToServer(item.server) }
                            } label: {
                                HStack(spacing: 14) {
                                    isoChip(siteToISO(item.server.site))
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.server.cityName)
                                            .font(.kataDisplay(18, weight: .medium))
                                            .foregroundStyle(Color.kataIce)
                                        Text(item.server.nodeId)
                                            .font(.kataMono(10))
                                            .foregroundStyle(Color.kataChampagne.opacity(0.4))
                                    }
                                    Spacer()
                                    if let ms = item.milliseconds {
                                        Text("\(Int(ms)) ms")
                                            .font(.kataMono(12))
                                            .foregroundStyle(Color.kataChampagne)
                                    } else {
                                        Text("—")
                                            .font(.kataMono(12))
                                            .foregroundStyle(Color.kataChampagne.opacity(0.35))
                                    }
                                    if servers.selectedServer?.nodeId == item.server.nodeId {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(Color.kataGold)
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 18)
                            }
                            .buttonStyle(.plain)

                            if idx < regionServers.count - 1 {
                                ledgerDivider
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(region.label)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.kataMidnight, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task {
            if servers.servers.isEmpty { await servers.refresh() }
        }
    }

    // MARK: - Load badge

    private func loadBadge(score: Int) -> some View {
        let (label, opacity): (String, Double) = {
            switch score {
            case 0..<200:   return ("IDLE",  0.45)
            case 200..<500: return ("LIGHT", 0.55)
            case 500..<700: return ("BUSY",  0.75)
            default:        return ("HEAVY", 0.9)
            }
        }()
        return Text(label)
            .font(.kataMono(9, weight: .bold))
            .kerning(0.8)
            .foregroundStyle(Color.kataChampagne.opacity(opacity))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .overlay(
                Capsule()
                    .stroke(Color.kataGold.opacity(0.3), lineWidth: 0.5)
            )
    }

    // MARK: - Logic

    private var shouldShowMeasuringIndicator: Bool {
        servers.servers.allSatisfy { $0.milliseconds == nil } && servers.error == nil && !servers.servers.isEmpty
    }

    private func bestPingMs(for region: RegionSummary) -> Double? {
        servers.servers
            .filter { $0.server.region == region.id && $0.milliseconds != nil }
            .min { ($0.milliseconds ?? Double.infinity) < ($1.milliseconds ?? Double.infinity) }?
            .milliseconds
    }

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

    private func nodeCountDescription(_ region: RegionSummary) -> String {
        let n = region.healthyNodeCount
        return n == 1 ? "1 server online" : "\(n) servers online"
    }

    /// Map region id or continent code to a 2-letter ISO country code for the chip.
    /// Falls back to first 2 chars of region label uppercased.
    private func regionISOCode(_ region: RegionSummary) -> String {
        // Try matching common region ids
        let id = region.id.lowercased()
        if id.contains("us") || id.contains("ash") || id.contains("iad") ||
           id.contains("hil") || id.contains("ewr") || id.contains("pdx") { return "US" }
        if id.contains("eu") || id.contains("nbg") || id.contains("hel") ||
           id.contains("de") || id.contains("fi")  { return "EU" }
        if id.contains("sg") || id.contains("sin") || id.contains("sgp") { return "SG" }
        if id.contains("jp") || id.contains("nrt") || id.contains("tok") { return "JP" }
        if id.contains("in") || id.contains("bom") || id.contains("mum") { return "IN" }
        if id.contains("ca") || id.contains("bhs") || id.contains("tor") { return "CA" }
        if id.contains("au") || id.contains("syd") { return "AU" }
        if id.contains("uk") || id.contains("lon") { return "GB" }
        if id.contains("br") || id.contains("sao") { return "BR" }
        // Continent fallback
        switch region.continent {
        case "NA": return "US"
        case "EU": return "EU"
        case "AS": return "SG"
        case "SA": return "BR"
        case "OC": return "AU"
        case "AF": return "ZA"
        default:   break
        }
        // Last resort: first 2 chars of label
        let prefix = String(region.label.filter { $0.isLetter }.prefix(2)).uppercased()
        return prefix.isEmpty ? "??" : prefix
    }


    // Maps a site code (e.g. "sgp2", "nbg1") to a 2-letter ISO country code.
    private func siteToISO(_ site: String) -> String {
        let s = site.lowercased()
        if s.hasPrefix("sgp") || s.hasPrefix("sg") { return "SG" }
        if s.hasPrefix("nrt") || s.hasPrefix("jp") { return "JP" }
        if s.hasPrefix("bom") { return "IN" }
        if s.hasPrefix("ewr") || s.hasPrefix("ash") || s.hasPrefix("iad") ||
           s.hasPrefix("hil") || s.hasPrefix("pdx") { return "US" }
        if s.hasPrefix("nbg") { return "DE" }
        if s.hasPrefix("hel") { return "FI" }
        if s.hasPrefix("bhs") { return "CA" }
        if s.hasPrefix("syd") { return "AU" }
        let prefix = String(site.filter { $0.isLetter }.prefix(2)).uppercased()
        return prefix.isEmpty ? "??" : prefix
    }

    private func loadRegions() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            regions = try await APIClient.shared.fetchRegions()
        } catch {
            errorMessage = "Could not load regions — \(error.localizedDescription)"
        }
    }

}

#Preview {
    RegionPickerView()
        .environmentObject(WireGuardManager())
}
