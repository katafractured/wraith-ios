// MacDnsStatsView.swift
// WraithVPNMac
//
// macOS port of DnsStatsView.

import SwiftUI
import KatafractStyle
import Charts

struct MacDnsStatsView: View {

    @State private var stats: DnsStatsResponse? = nil
    @State private var isLoading = true
    @State private var error: String? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("DNS Protection Stats")
                    .font(KFFont.heading(16))
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(Color.kfAccentBlue)
                }
                .buttonStyle(.plain)
                .disabled(isLoading)
                Button("Done") { dismiss() }
                    .foregroundStyle(Color.kfAccentBlue)
                    .buttonStyle(.plain)
                    .padding(.leading, 8)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.kfSurface)

            Divider().background(Color.kfBorder)

            Group {
                if isLoading && stats == nil {
                    VStack(spacing: 12) {
                        KataProgressRing()
                        Text("Fetching stats…")
                            .font(KFFont.caption(13))
                            .foregroundStyle(Color.kfTextMuted)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let err = error {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(Color.kfError)
                        Text(err)
                            .font(KFFont.caption(13))
                            .foregroundStyle(Color.kfTextMuted)
                            .multilineTextAlignment(.center)
                        Button("Retry") { Task { await load() } }
                            .foregroundStyle(Color.kfAccentBlue)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let stats = stats {
                    ScrollView {
                        VStack(spacing: 16) {
                            // Block rate
                            VStack(spacing: 4) {
                                Text(String(format: "%.1f%%", stats.blockRatePercent))
                                    .font(.system(size: 48, weight: .bold, design: .rounded))
                                    .foregroundStyle(Color.kfAccentBlue)
                                Text("of queries blocked")
                                    .font(KFFont.caption(12))
                                    .foregroundStyle(Color.kfTextMuted)
                                Text("\(formatNumber(stats.totalQueries)) total queries")
                                    .font(KFFont.caption(12))
                                    .foregroundStyle(Color.kfTextMuted)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(16)
                            .background(Color.kfSurface)
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                            // Category chips
                            HStack(spacing: 12) {
                                categoryChip(icon: "eye.slash.fill", color: Color(hex: "#f97316"),
                                             label: "Ads", count: stats.adsBlocked)
                                categoryChip(icon: "antenna.radiowaves.left.and.right.slash", color: Color(hex: "#a855f7"),
                                             label: "Trackers", count: stats.trackersBlocked)
                                categoryChip(icon: "exclamationmark.shield.fill", color: Color.kfError,
                                             label: "Malware", count: stats.malwareBlocked)
                            }

                            // Bar chart
                            if !stats.dailyHistory.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("DAILY HISTORY (LAST 30 DAYS)")
                                        .font(KFFont.caption(10, weight: .bold))
                                        .kerning(1.2)
                                        .foregroundStyle(Color.kfTextMuted)

                                    let history = Array(stats.dailyHistory.suffix(30))
                                    let maxBlocked = history.map { $0.blocked }.max() ?? 1

                                    HStack(alignment: .bottom, spacing: 2) {
                                        ForEach(history, id: \.id) { stat in
                                            let height = maxBlocked > 0 ? CGFloat(stat.blocked) / CGFloat(maxBlocked) * 100 : 0
                                            Rectangle()
                                                .fill(Color.kfAccentBlue)
                                                .frame(height: max(2, height))
                                                .frame(maxWidth: .infinity)
                                        }
                                    }
                                    .frame(height: 100)
                                }
                                .padding(16)
                                .background(Color.kfSurface)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                        .padding(16)
                    }
                }
            }
        }
        .frame(width: 420)
        .frame(minHeight: 380)
        .background(Color.kfBackground)
        .preferredColorScheme(.dark)
        .task { await load() }
    }

    private func categoryChip(icon: String, color: Color, label: String, count: Int) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(color)
            Text(formatNumber(count))
                .font(KFFont.mono(14))
                .fontWeight(.semibold)
                .foregroundStyle(.white)
            Text(label)
                .font(KFFont.caption(11))
                .foregroundStyle(Color.kfTextMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(Color.kfSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func load() async {
        isLoading = true
        error = nil
        do { stats = try await APIClient.shared.fetchDnsStats() }
        catch { self.error = error.localizedDescription }
        isLoading = false
    }

    private func formatNumber(_ n: Int) -> String {
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        return fmt.string(from: NSNumber(value: n)) ?? String(n)
    }
}
