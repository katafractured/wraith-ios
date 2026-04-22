// MacAchievementsView.swift
// WraithVPNMac
//
// macOS port of AchievementsView.

import SwiftUI
import KatafractStyle

struct MacAchievementsView: View {

    @State private var response: AchievementsResponse? = nil
    @State private var isLoading = true
    @State private var error: String? = nil
    @State private var selectedAchievement: AchievementItem? = nil
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 160))]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Achievements")
                    .font(KFFont.heading(16))
                    .foregroundStyle(.white)
                Spacer()
                Button("Done") { dismiss() }
                    .foregroundStyle(Color.kfAccentBlue)
                    .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.kfSurface)

            Divider().background(Color.kfBorder)

            Group {
                if isLoading {
                    VStack(spacing: 12) {
                        KataProgressRing()
                        Text("Loading achievements…")
                            .font(KFFont.caption(13))
                            .foregroundStyle(Color.kfTextMuted)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let err = error {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
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
                } else if let resp = response {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            if resp.activeStreakDays > 0 {
                                HStack(spacing: 12) {
                                    Image(systemName: "flame.fill")
                                        .font(.system(size: 28))
                                        .foregroundStyle(Color(hex: "#f97316"))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("\(resp.activeStreakDays) Day Streak")
                                            .font(KFFont.heading(16))
                                            .foregroundStyle(.white)
                                        Text("Longest: \(resp.longestStreakDays) days")
                                            .font(KFFont.caption(12))
                                            .foregroundStyle(Color.kfTextMuted)
                                    }
                                    Spacer()
                                }
                                .padding(12)
                                .background(LinearGradient(colors: [Color(hex: "f97316"), Color(hex: "ea580c")],
                                                           startPoint: .topLeading, endPoint: .bottomTrailing))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }

                            let unlocked = resp.achievements.filter { $0.unlocked }
                            let locked   = resp.achievements.filter { !$0.unlocked }

                            if !unlocked.isEmpty {
                                Text("\(unlocked.count) UNLOCKED")
                                    .font(KFFont.caption(10, weight: .bold))
                                    .kerning(1.5)
                                    .foregroundStyle(Color.kfTextMuted)
                                LazyVGrid(columns: columns, spacing: 8) {
                                    ForEach(unlocked) { item in
                                        MacAchievementCard(item: item)
                                            .onTapGesture { selectedAchievement = item }
                                    }
                                }
                            }

                            if !locked.isEmpty {
                                Text("\(locked.count) REMAINING")
                                    .font(KFFont.caption(10, weight: .bold))
                                    .kerning(1.5)
                                    .foregroundStyle(Color.kfTextMuted)
                                LazyVGrid(columns: columns, spacing: 8) {
                                    ForEach(locked) { item in
                                        MacAchievementCard(item: item)
                                            .onTapGesture { selectedAchievement = item }
                                    }
                                }
                            }
                        }
                        .padding(16)
                    }
                }
            }
        }
        .frame(width: 500)
        .frame(minHeight: 420)
        .background(Color.kfBackground)
        .preferredColorScheme(.dark)
        .task { await load() }
        .popover(item: $selectedAchievement) { item in
            achievementDetail(item)
        }
    }

    private func achievementDetail(_ item: AchievementItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: item.icon)
                    .font(.system(size: 28))
                    .foregroundStyle(item.unlocked ? Color.kfAccentBlue : Color.kfTextMuted)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(KFFont.heading(15))
                        .foregroundStyle(.white)
                    Text(item.description)
                        .font(KFFont.caption(12))
                        .foregroundStyle(Color.kfTextMuted)
                }
            }
            if item.unlocked, let ts = item.unlockedAt {
                let date = Date(timeIntervalSince1970: TimeInterval(ts))
                Text("Unlocked \(date.formatted(date: .abbreviated, time: .omitted))")
                    .font(KFFont.mono(11))
                    .foregroundStyle(Color.kfAccentBlue)
            } else if !item.unlocked, let label = item.progressLabel {
                Text(label)
                    .font(KFFont.mono(11))
                    .foregroundStyle(Color.kfTextMuted)
            }
        }
        .padding(16)
        .frame(minWidth: 240)
        .background(Color.kfSurface)
        .preferredColorScheme(.dark)
    }

    private func load() async {
        isLoading = true
        error = nil
        do { response = try await APIClient.shared.fetchAchievements() }
        catch { self.error = error.localizedDescription }
        isLoading = false
    }
}

// MARK: - Small achievement card for Mac grid

private struct MacAchievementCard: View {
    let item: AchievementItem

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.kfSurface

            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: item.icon)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(item.unlocked ? Color.kfAccentBlue : Color.kfTextMuted)
                Spacer()
                Text(item.title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(item.unlocked ? Color.white : Color.kfTextMuted)
                    .lineLimit(1)
                Text(item.description)
                    .font(.system(size: 9))
                    .foregroundStyle(Color.kfTextMuted.opacity(0.7))
                    .lineLimit(2)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if item.unlocked {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.kfConnected)
                    .padding(6)
            } else {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.kfTextMuted)
                    .padding(8)
            }
        }
        .frame(height: 120)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(item.unlocked ? Color.kfAccentBlue.opacity(0.3) : Color.kfBorder, lineWidth: 1)
        )
    }
}
