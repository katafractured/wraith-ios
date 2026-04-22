// PaywallView.swift
// WraithVPN
//
// Subscription paywall — 3-tier ladder (Haven Pro / Enclave / Enclave+)
// with monthly/annual toggle per tier and real App Store prices.

import SwiftUI
import KatafractStyle
import StoreKit

struct PaywallView: View {

    @EnvironmentObject var storeKit: StoreKitManager
    @Environment(\.dismiss) private var dismiss
    var onContinueFree: (() -> Void)? = nil

    // Default: Enclave annual (best value)
    @State private var selectedProductId: String = WraithProduct.enclaveAnnual.rawValue
    @State private var selectedTier: WraithTier  = .enclave
    @State private var showAnnual: Bool          = true
    @State private var showTokenEntry = false

    // MARK: - Derived

    /// The currently-selected WraithProduct enum value.
    private var selectedProduct: WraithProduct {
        switch (selectedTier, showAnnual) {
        case (.enclave,    true):  return .enclaveAnnual
        case (.enclave,    false): return .enclaveMonthly
        case (.sovereign,  true):  return .sovereignAnnual
        case (.sovereign,  false): return .sovereignMonthly
        default:                   return .enclaveAnnual
        }
    }

    /// App Store Product for the current selection.
    private var activeStoreProduct: Product? {
        storeKit.products.first { $0.id == selectedProduct.rawValue }
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.height < 780

            ZStack {
                LinearGradient(
                    colors: [Color(hex: "#0d0f14"), Color(hex: "#110d1a")],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: compact ? KFSpacing.lg : KFSpacing.xl) {
                        header
                        tierSelector
                        billingToggle
                        featureCard
                        ctaButton
                        freeTierButton
                        legalFooter
                    }
                    .padding(KFSpacing.lg)
                    .padding(.top, compact ? KFSpacing.sm : KFSpacing.lg)
                }
            }
        }
        .navigationTitle("Subscribe")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.kfBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .preferredColorScheme(.dark)
        .onChange(of: selectedTier) { _, _ in
            selectedProductId = selectedProduct.rawValue
        }
        .onChange(of: showAnnual) { _, _ in
            selectedProductId = selectedProduct.rawValue
        }
        .alert("Purchase Error", isPresented: .init(
            get: { storeKit.purchaseError != nil },
            set: { if !$0 { storeKit.purchaseError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(storeKit.purchaseError ?? "")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: KFSpacing.sm) {
            Image("OnboardingPaywallHero")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 280, maxHeight: 200)
                .shadow(color: Color.kfAccentPurple.opacity(0.2), radius: 28, y: 14)

            Text("Choose Your Privacy")
                .font(KFFont.display(30))
                .foregroundStyle(.white)

            Text("Haven DNS is free forever. Enclave adds VPN. Sovereign adds storage & sync.")
                .font(KFFont.body(15))
                .foregroundStyle(Color.kfTextSecondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Tier selector (2 cards: Enclave + Sovereign)

    private var tierSelector: some View {
        HStack(spacing: KFSpacing.sm) {
            ForEach([WraithTier.enclave, .sovereign], id: \.rawValue) { tier in
                TierTabView(
                    tier: tier,
                    isSelected: selectedTier == tier
                )
                .onTapGesture { selectedTier = tier }
            }
        }
    }

    // MARK: - Annual / Monthly toggle

    private var billingToggle: some View {
        HStack(spacing: 0) {
            togglePill(label: "Monthly", isActive: !showAnnual) {
                withAnimation(.easeInOut(duration: 0.2)) { showAnnual = false }
            }
            togglePill(label: "Annual", isActive: showAnnual, badge: savingsBadge) {
                withAnimation(.easeInOut(duration: 0.2)) { showAnnual = true }
            }
        }
        .background(Color.kfSurface)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.kfBorder, lineWidth: 1))
    }

    private func togglePill(label: String, isActive: Bool, badge: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(label)
                    .font(KFFont.caption(13, weight: .semibold))
                    .foregroundStyle(isActive ? .white : Color.kfTextMuted)
                if let badge {
                    Text(badge)
                        .font(KFFont.caption(10, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.kfConnected)
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, KFSpacing.md)
            .padding(.vertical, 10)
            .background(isActive ? LinearGradient.kfAccent : LinearGradient(colors: [Color.clear], startPoint: .top, endPoint: .bottom))
            .clipShape(Capsule())
        }
        .animation(.easeInOut(duration: 0.2), value: isActive)
    }

    /// Compute annual savings vs monthly × 12.
    private var savingsBadge: String? {
        let monthlyId = monthlyProduct(for: selectedTier)?.rawValue
        let annualId = annualProduct(for: selectedTier)?.rawValue

        guard let mId = monthlyId,
              let aId = annualId,
              let monthly = storeKit.products.first(where: { $0.id == mId }),
              let annual  = storeKit.products.first(where: { $0.id == aId }) else {
            return "Save ~33%"
        }
        let monthlyAnnualised = monthly.price * 12
        guard monthlyAnnualised > 0 else { return nil }
        let savingDecimal = (monthlyAnnualised - annual.price) / monthlyAnnualised * 100
        guard savingDecimal > 0 else { return nil }
        let savingInt = Int(NSDecimalNumber(decimal: savingDecimal).doubleValue.rounded())
        guard savingInt > 0 else { return nil }
        return "Save \(savingInt)%"
    }

    private func monthlyProduct(for tier: WraithTier) -> WraithProduct? {
        switch tier {
        case .enclave:
            return .enclaveMonthly
        case .sovereign:
            return .sovereignMonthly
        case .haven, .seats:
            return nil
        }
    }

    private func annualProduct(for tier: WraithTier) -> WraithProduct? {
        switch tier {
        case .enclave:
            return .enclaveAnnual
        case .sovereign:
            return .sovereignAnnual
        case .haven, .seats:
            return nil
        }
    }

    // MARK: - Feature card

    private var featureCard: some View {
        VStack(alignment: .leading, spacing: KFSpacing.sm) {
            if storeKit.isLoading && storeKit.products.isEmpty {
                KataProgressRing()
                    .tint(Color.kfAccentBlue)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                // Price line
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let product = activeStoreProduct {
                        Text(product.displayPrice)
                            .font(KFFont.display(28))
                            .foregroundStyle(.white)
                        Text(showAnnual ? "/ year" : "/ month")
                            .font(KFFont.body(14))
                            .foregroundStyle(Color.kfTextMuted)
                        if showAnnual, let monthly = monthlyEquivalent {
                            Text("(\(monthly)/mo)")
                                .font(KFFont.caption(12))
                                .foregroundStyle(Color.kfTextMuted)
                        }
                    } else {
                        Text("Loading…")
                            .font(KFFont.body(15))
                            .foregroundStyle(Color.kfTextMuted)
                    }
                    Spacer()
                }

                Divider().background(Color.kfBorder)

                // Feature list
                ForEach(selectedTier.features, id: \.self) { feature in
                    FeatureRow(icon: featureIcon(feature), text: feature,
                               accentHex: selectedTier.accentColorHex)
                }
            }
        }
        .padding(KFSpacing.md)
        .kfCard()
        .animation(.easeInOut(duration: 0.2), value: selectedTier)
    }

    private var monthlyEquivalent: String? {
        guard let product = activeStoreProduct else { return nil }
        let monthly = product.price / 12
        return monthly.formatted(product.priceFormatStyle)
    }

    private func featureIcon(_ feature: String) -> String {
        if feature.contains("DNS") || feature.contains("tracker") || feature.contains("ad") { return "shield.lefthalf.filled" }
        if feature.contains("VPN") || feature.contains("WireGuard") { return "bolt.fill" }
        if feature.contains("multi-hop") || feature.contains("Multi-hop") || feature.contains("2 nodes") { return "arrow.triangle.branch" }
        if feature.contains("Kill switch") { return "xmark.shield.fill" }
        if feature.contains("device") || feature.contains("5 device") { return "iphone.and.arrow.forward" }
        if feature.contains("exit node") || feature.contains("global") { return "network.badge.shield.half.filled" }
        if feature.contains("Maximum") || feature.contains("privacy") { return "lock.fill" }
        if feature.contains("Entry") || feature.contains("separation") { return "arrow.left.arrow.right" }
        if feature.contains("Everything") { return "checkmark.seal.fill" }
        return "checkmark.circle"
    }

    // MARK: - CTA button

    private var ctaButton: some View {
        Button {
            guard let product = activeStoreProduct else { return }
            Task { await storeKit.purchase(product) }
        } label: {
            Group {
                if storeKit.isLoading {
                    KataProgressRing()
                } else {
                    Text("Subscribe to \(selectedTier.displayName)")
                        .font(KFFont.heading(18))
                        .foregroundStyle(.white)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, KFSpacing.md)
            .background(LinearGradient.kfAccent)
            .clipShape(Capsule())
        }
        .disabled(storeKit.isLoading || activeStoreProduct == nil)
        .shadow(color: Color.kfAccentPurple.opacity(0.25), radius: 24, y: 14)
    }

    // MARK: - Free Haven button

    private var freeTierButton: some View {
        VStack(spacing: KFSpacing.sm) {
            VStack(alignment: .leading, spacing: KFSpacing.xs) {
                Text("Haven DNS is free forever")
                    .font(KFFont.heading(18))
                    .foregroundStyle(.white)
                Text("Haven DNS protects every app on your device — blocks ads, trackers, and malware at the DNS level. Works on all networks, no account needed. Upgrade to Enclave for VPN protection or Sovereign for cloud storage and sync.")
                    .font(KFFont.body(14))
                    .foregroundStyle(Color.kfTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                onContinueFree?()
                if onContinueFree == nil { dismiss() }
            } label: {
                VStack(spacing: 8) {
                    Text("Start With Haven DNS Free")
                        .font(KFFont.heading(16))
                        .foregroundStyle(.white)
                    Text("Complete DNS protection — no card or subscription required.")
                        .font(KFFont.caption(12))
                        .foregroundStyle(Color.kfTextSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(KFSpacing.md)
                .background(
                    LinearGradient(
                        colors: [
                            Color.kfSurfaceElevated.opacity(0.96),
                            Color.kfSurface.opacity(0.98)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: KFRadius.lg, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: KFRadius.lg, style: .continuous)
                        .stroke(Color.kfAccentBlue.opacity(0.22), lineWidth: 1)
                )
            }
        }
        .padding(KFSpacing.md)
        .kfCard()
    }

    // MARK: - Legal footer

    private var legalFooter: some View {
        VStack(spacing: KFSpacing.xs) {
            Button("Restore Purchase") {
                Task { await storeKit.restorePurchases() }
            }
            .font(KFFont.caption(13))
            .foregroundStyle(Color.kfAccentBlue)

            Text("No account required. App Store subscribers can restore via Apple ID. Payment will be charged to your Apple ID at confirmation of purchase. Subscriptions renew automatically unless cancelled at least 24 hours before the end of the current period.")
                .font(KFFont.caption(11))
                .foregroundStyle(Color.kfTextMuted)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
        }
    }
}

// MARK: - Tier tab

private struct TierTabView: View {
    let tier: WraithTier
    let isSelected: Bool

    private var accent: Color { Color(hex: tier.accentColorHex) }

    var body: some View {
        VStack(spacing: 4) {
            Text(tier.displayName)
                .font(KFFont.caption(12, weight: .semibold))
                .foregroundStyle(isSelected ? accent : Color.kfTextMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: KFRadius.md, style: .continuous)
                .fill(isSelected ? accent.opacity(0.12) : Color.kfSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: KFRadius.md, style: .continuous)
                .strokeBorder(isSelected ? accent : Color.kfBorder, lineWidth: isSelected ? 1.5 : 1)
        )
        .animation(.easeInOut(duration: 0.18), value: isSelected)
    }
}

// MARK: - Feature row

private struct FeatureRow: View {
    let icon: String
    let text: String
    let accentHex: String

    var body: some View {
        HStack(spacing: KFSpacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(Color(hex: accentHex))
                .frame(width: 20)
            Text(text)
                .font(KFFont.body(14))
                .foregroundStyle(Color.kfTextSecondary)
            Spacer()
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        PaywallView()
            .environmentObject(StoreKitManager())
    }
}
