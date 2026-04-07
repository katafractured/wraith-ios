import SwiftUI

// MARK: - Tier Gradient Helper

private enum AchievementTier {
    case starter, grind, rare, epic, legendary, special

    static func from(id: String) -> AchievementTier {
        switch id {
        case "shield_activated", "first_block", "veil_connected":
            return .starter
        case "blocked_100", "streak_3", "ads_1k":
            return .grind
        case "blocked_1k", "streak_7", "ads_5k", "trackers_500", "malware_10":
            return .rare
        case "blocked_10k", "streak_30":
            return .epic
        case "blocked_100k", "streak_90", "blocked_1m", "streak_365":
            return .legendary
        case "early_adopter", "full_armor":
            return .special
        default:
            return .starter
        }
    }

    var gradient: LinearGradient {
        switch self {
        case .starter:
            return LinearGradient(
                colors: [Color(hex: "3b82f6"), Color(hex: "1d4ed8")],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        case .grind:
            return LinearGradient(
                colors: [Color(hex: "f97316"), Color(hex: "c2410c")],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        case .rare:
            return LinearGradient(
                colors: [Color(hex: "06b6d4"), Color(hex: "0369a1")],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        case .epic:
            return LinearGradient(
                colors: [Color(hex: "eab308"), Color(hex: "a16207")],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        case .legendary:
            return LinearGradient(
                colors: [Color(hex: "a855f7"), Color(hex: "6b21a8")],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        case .special:
            return LinearGradient(
                colors: [Color(hex: "3b82f6"), Color(hex: "7c3aed")],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
    }

    var glowColor: Color {
        switch self {
        case .starter:  return Color(hex: "3b82f6")
        case .grind:    return Color(hex: "f97316")
        case .rare:     return Color(hex: "06b6d4")
        case .epic:     return Color(hex: "eab308")
        case .legendary: return Color(hex: "a855f7")
        case .special:  return Color(hex: "6366f1")
        }
    }
}

// MARK: - Streak Banner

private struct StreakBanner: View {
    let activeStreak: Int
    let longestStreak: Int

    var body: some View {
        HStack(spacing: KFSpacing.md) {
            Image(systemName: "flame.fill")
                .font(.system(size: 44))
                .foregroundColor(.white)
                .shadow(color: Color(hex: "fb923c").opacity(0.8), radius: 12)

            VStack(alignment: .leading, spacing: 4) {
                Text("\(activeStreak) Day Streak")
                    .font(KFFont.heading(22))
                    .foregroundStyle(Color.white)
                Text("Longest: \(longestStreak) days")
                    .font(KFFont.body(14))
                    .foregroundStyle(Color.white.opacity(0.7))
            }

            Spacer()
        }
        .padding(KFSpacing.md)
        .background(
            LinearGradient(
                colors: [Color(hex: "f97316"), Color(hex: "ea580c")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: KFRadius.lg))
        .shadow(color: Color(hex: "f97316").opacity(0.35), radius: 16, x: 0, y: 4)
    }
}

// MARK: - Achievement Card

private struct AchievementCard: View {
    let item: AchievementItem

    private var tier: AchievementTier { AchievementTier.from(id: item.id) }

    private var unlockLabel: String? {
        guard item.unlocked, let ts = item.unlockedAt else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(ts))
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d"
        return fmt.string(from: date)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Card background
            Group {
                if item.unlocked {
                    tier.gradient
                } else {
                    LinearGradient(colors: [Color.kfSurface, Color.kfSurface], startPoint: .top, endPoint: .bottom)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: KFRadius.md))
            .overlay(
                RoundedRectangle(cornerRadius: KFRadius.md)
                    .stroke(item.unlocked ? tier.glowColor.opacity(0.5) : Color.kfBorder, lineWidth: 1)
            )
            .shadow(
                color: item.unlocked ? tier.glowColor.opacity(0.4) : .clear,
                radius: 12, x: 0, y: 4
            )

            // Card content
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: item.icon)
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(item.unlocked ? Color.white : Color.kfTextMuted)
                    .scaleEffect(item.unlocked ? 1.0 : 0.85)

                Spacer()

                Text(item.title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(item.unlocked ? Color.white : Color.kfTextMuted)
                    .lineLimit(1)

                Text(item.description)
                    .font(.system(size: 10))
                    .foregroundStyle(item.unlocked ? Color.white.opacity(0.75) : Color.kfTextMuted.opacity(0.7))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if let label = unlockLabel {
                    Text(label)
                        .font(KFFont.mono(10))
                        .foregroundStyle(Color.white.opacity(0.6))
                }
            }
            .padding(KFSpacing.md)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            // Badge: checkmark (unlocked) or lock (locked)
            if item.unlocked {
                ZStack {
                    Circle()
                        .fill(Color.kfConnected)
                        .frame(width: 20, height: 20)
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.white)
                }
                .padding(8)
            } else {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.kfTextMuted)
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
        .frame(height: 160)
    }
}

// MARK: - Section Header

private struct SectionHeader: View {
    let label: String

    var body: some View {
        Text(label)
            .font(KFFont.caption(11, weight: .bold))
            .kerning(1.5)
            .foregroundStyle(Color.kfTextMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - AchievementsView

struct AchievementsView: View {
    @State private var response: AchievementsResponse? = nil
    @State private var isLoading = true
    @State private var error: String? = nil

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        NavigationStack {
            ZStack {
                Color.kfBackground.ignoresSafeArea()

                if isLoading {
                    ProgressView()
                        .tint(Color.kfAccentBlue)
                } else if let err = error {
                    errorView(message: err)
                } else if let resp = response {
                    contentView(resp)
                }
            }
            .navigationTitle("Achievements")
            .navigationBarTitleDisplayMode(.large)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .task { await load() }
    }

    // MARK: Content

    @ViewBuilder
    private func contentView(_ resp: AchievementsResponse) -> some View {
        let unlocked = resp.achievements.filter { $0.unlocked }
        let locked   = resp.achievements.filter { !$0.unlocked }

        ScrollView {
            LazyVStack(alignment: .leading, spacing: KFSpacing.lg) {
                // Streak banner
                if resp.activeStreakDays > 0 {
                    StreakBanner(
                        activeStreak: resp.activeStreakDays,
                        longestStreak: resp.longestStreakDays
                    )
                }

                // Unlocked section
                if !unlocked.isEmpty {
                    SectionHeader(label: "\(unlocked.count) UNLOCKED")
                    LazyVGrid(columns: columns, spacing: KFSpacing.sm) {
                        ForEach(unlocked) { item in
                            AchievementCard(item: item)
                        }
                    }
                }

                // Locked section
                if !locked.isEmpty {
                    SectionHeader(label: "\(locked.count) REMAINING")
                    LazyVGrid(columns: columns, spacing: KFSpacing.sm) {
                        ForEach(locked) { item in
                            AchievementCard(item: item)
                        }
                    }
                }

                if unlocked.isEmpty && locked.isEmpty {
                    Text("No achievements yet.")
                        .font(KFFont.body(15))
                        .foregroundStyle(Color.kfTextSecondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, KFSpacing.xl)
                }
            }
            .padding(.horizontal, KFSpacing.md)
            .padding(.vertical, KFSpacing.md)
        }
    }

    // MARK: Error

    @ViewBuilder
    private func errorView(message: String) -> some View {
        VStack(spacing: KFSpacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(Color.kfError)
            Text(message)
                .font(KFFont.body(15))
                .foregroundStyle(Color.kfTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, KFSpacing.xl)
            Button {
                Task { await load() }
            } label: {
                Text("Retry")
                    .font(KFFont.caption(15, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, KFSpacing.lg)
                    .padding(.vertical, KFSpacing.sm)
                    .background(Color.kfAccentBlue)
                    .clipShape(RoundedRectangle(cornerRadius: KFRadius.md))
            }
        }
    }

    // MARK: Data fetch

    private func load() async {
        guard KeychainHelper.shared.readOptional(for: .subscriptionToken) != nil else {
            error = "No active subscription"
            isLoading = false
            return
        }
        isLoading = true
        error = nil
        do {
            response = try await APIClient.shared.fetchAchievements()
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}
