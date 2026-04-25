// DnsStatsView.swift
// WraithVPN
//
// 30-day DNS query statistics and blocking performance.
// Shows block rate, category breakdowns (ads/trackers/malware),
// and daily history in a simple bar chart.

import SwiftUI
import KatafractStyle

struct DnsStatsView: View {

    @State private var stats: DnsStatsResponse? = nil
    @State private var isLoading = true
    @State private var error: String? = nil

    var body: some View {
        ZStack {
            Color.kfBackground.ignoresSafeArea()

            Group {
                if let stats = stats {
                    ScrollView {
                        VStack(spacing: KFSpacing.lg) {
                            statsHeaderCard(stats)
                            categoryRow(stats)
                            historyCard(stats)
                            Spacer(minLength: KFSpacing.lg)
                        }
                        .padding(KFSpacing.lg)
                    }
                    .refreshable { await load() }
                } else if let error = error {
                    errorState(error)
                } else {
                    loadingState
                }
            }
        }
        .navigationTitle("Protection Stats")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.kfBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .preferredColorScheme(.dark)
        .task { await load() }
    }

    // MARK: - Stats header: block rate + total queries

    private func statsHeaderCard(_ stats: DnsStatsResponse) -> some View {
        VStack(spacing: KFSpacing.md) {
            Text(String(format: "%.1f%%", stats.blockRatePercent))
                .font(.system(size: 52, weight: .bold, design: .rounded))
                .foregroundStyle(Color.kfAccentBlue)

            Text("of queries blocked")
                .font(KFFont.caption(13))
                .foregroundStyle(Color.kfTextMuted)

            Text("\(formatNumber(stats.totalQueries)) total queries")
                .font(KFFont.caption(13))
                .foregroundStyle(Color.kfTextMuted)

            if let since = stats.since {
                Text("Since \(since)")
                    .font(KFFont.caption(12))
                    .foregroundStyle(Color.kfTextMuted)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(KFSpacing.lg)
        .background(Color.kfSurface)
        .kfCard()
    }

    // MARK: - Category chips: Ads / Trackers / Malware

    private func categoryRow(_ stats: DnsStatsResponse) -> some View {
        HStack(spacing: KFSpacing.md) {
            categoryChip(
                icon: "eye.slash.fill",
                color: Color(hex: "#f97316"),
                label: "Ads",
                count: stats.adsBlocked
            )

            categoryChip(
                icon: "antenna.radiowaves.left.and.right.slash",
                color: Color(hex: "#a855f7"),
                label: "Trackers",
                count: stats.trackersBlocked
            )

            categoryChip(
                icon: "exclamationmark.shield.fill",
                color: Color.kfError,
                label: "Malware",
                count: stats.malwareBlocked
            )
        }
        .frame(height: 120)
    }

    private func categoryChip(icon: String, color: Color, label: String, count: Int) -> some View {
        VStack(spacing: KFSpacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(color)

            Text(formatNumber(count))
                .font(KFFont.mono(15))
                .fontWeight(.semibold)
                .foregroundStyle(.white)

            Text(label)
                .font(KFFont.caption(11))
                .foregroundStyle(Color.kfTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(KFSpacing.md)
        .background(Color.kfSurface)
        .kfCard()
    }

    // MARK: - 30-day history bar chart

    private func historyCard(_ stats: DnsStatsResponse) -> some View {
        VStack(alignment: .leading, spacing: KFSpacing.md) {
            Text("DAILY HISTORY (LAST 30 DAYS)")
                .font(KFFont.caption(11))
                .fontWeight(.semibold)
                .foregroundStyle(Color.kfTextSecondary)
                .textCase(.uppercase)
                .tracking(0.5)

            if stats.dailyHistory.isEmpty {
                Text("No data yet")
                    .font(KFFont.body(14))
                    .foregroundStyle(Color.kfTextMuted)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .frame(height: 120)
            } else {
                barChart(stats.dailyHistory)
            }
        }
        .padding(KFSpacing.lg)
        .background(Color.kfSurface)
        .kfCard()
    }

    private func barChart(_ history: [DailyDNSStat]) -> some View {
        let maxBlocked = history.map { $0.blocked }.max() ?? 1
        let displayItems = history.suffix(30)

        return HStack(alignment: .bottom, spacing: 3) {
            ForEach(displayItems, id: \.id) { stat in
                VStack(alignment: .center, spacing: 0) {
                    let height = maxBlocked > 0 ? CGFloat(stat.blocked) / CGFloat(maxBlocked) * 120 : 0
                    Rectangle()
                        .fill(Color.kfAccentBlue)
                        .frame(height: max(2, height))
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 120)
    }

    // MARK: - Loading & error states

    private var loadingState: some View {
        VStack(spacing: KFSpacing.lg) {
            KataProgressRing()
                .tint(Color.kfAccentBlue)

            Text("Fetching stats…")
                .font(KFFont.body(14))
                .foregroundStyle(Color.kfTextSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.kfBackground)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: KFSpacing.lg) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(Color.kfError)

            Text("Failed to load stats")
                .font(KFFont.heading(18))
                .foregroundStyle(.white)

            Text(message)
                .font(KFFont.body(13))
                .foregroundStyle(Color.kfTextSecondary)
                .multilineTextAlignment(.center)

            Button {
                Task { await load() }
            } label: {
                Text("Retry")
                    .font(KFFont.body(14))
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, KFSpacing.md)
                    .background(LinearGradient.kfAccent)
                    .clipShape(Capsule())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(KFSpacing.lg)
        .background(Color.kfBackground)
    }

    // MARK: - Lifecycle

    private func load() async {
        // Mock DNS stats for screenshots
        if ScreenshotMode.mockDnsStats {
            stats = DnsStatsResponse(
                totalQueries: 48217,
                adsBlocked: 4128,
                trackersBlocked: 2536,
                malwareBlocked: 187,
                blockedTotal: 6891,
                blockRatePercent: 14.3,
                since: "April 17",
                updatedAt: nil,
                dailyHistory: [
                    DailyDNSStat(date: "Apr 11", queries: 5200, blocked: 800),
                    DailyDNSStat(date: "Apr 12", queries: 6100, blocked: 950),
                    DailyDNSStat(date: "Apr 13", queries: 5000, blocked: 750),
                    DailyDNSStat(date: "Apr 14", queries: 4500, blocked: 650),
                    DailyDNSStat(date: "Apr 15", queries: 7200, blocked: 1100),
                    DailyDNSStat(date: "Apr 16", queries: 7500, blocked: 1200),
                    DailyDNSStat(date: "Apr 17", queries: 6000, blocked: 900),
                ]
            )
            isLoading = false
            return
        }

        isLoading = true
        error = nil

        do {
            stats = try await APIClient.shared.fetchDnsStats()
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    // MARK: - Helpers

    private func formatNumber(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: n)) ?? String(n)
    }
}

#Preview {
    NavigationStack {
        DnsStatsView()
            .environmentObject(StoreKitManager())
    }
}
