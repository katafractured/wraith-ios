// PaywallView.swift
// WraithVPN
//
// Subscription paywall shown when the user has no active token.
// Presents both products (monthly / annual), highlights the annual as "Best Value",
// and shows the feature list.

import SwiftUI
import StoreKit

struct PaywallView: View {

    @EnvironmentObject var storeKit: StoreKitManager
    @Environment(\.dismiss) private var dismiss
    var onContinueFree: (() -> Void)? = nil

    @State private var selectedProductId: String = WraithProduct.enclaveAnnual.rawValue
    @State private var showTokenEntry = false

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
                        featureList
                        productPicker
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
        .alert("Purchase Error", isPresented: .init(
            get: { storeKit.purchaseError != nil },
            set: { if !$0 { storeKit.purchaseError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(storeKit.purchaseError ?? "")
        }
    }

    // MARK: - Sub-views

    private var header: some View {
        VStack(spacing: KFSpacing.sm) {
            Image("OnboardingPaywallHero")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 320, maxHeight: 240)
                .shadow(color: Color.kfAccentPurple.opacity(0.2), radius: 28, y: 14)

            Text("WraithVPN")
                .font(KFFont.display(34))
                .foregroundStyle(.white)

            Text("Route through the Enclave with Haven DNS protection.")
                .font(KFFont.body(16))
                .foregroundStyle(Color.kfTextSecondary)
                .multilineTextAlignment(.center)

            HStack(spacing: KFSpacing.sm) {
                valueChip("WraithGates")
                valueChip("Enclave")
                valueChip("Haven DNS")
            }
            .padding(.top, 4)
        }
    }

    private func valueChip(_ label: String) -> some View {
        Text(label)
            .font(KFFont.caption(11, weight: .semibold))
            .foregroundStyle(Color.kfTextSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.kfSurface.opacity(0.92))
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.kfBorder, lineWidth: 1)
            )
    }

    private var featureList: some View {
        VStack(alignment: .leading, spacing: KFSpacing.sm) {
            FeatureRow(icon: "lock.fill",            text: "AES-256 + ChaCha20 encryption")
            FeatureRow(icon: "bolt.fill",            text: "Route through WraithGates with fast WireGuard performance")
            FeatureRow(icon: "shield.lefthalf.filled", text: "The Enclave adds a protected network layer for your traffic")
            FeatureRow(icon: "network.badge.shield.half.filled", text: "Haven DNS helps reduce ad and tracker traffic")
            FeatureRow(icon: "globe",                text: "Current nodes across the US, Germany, Finland, and Singapore")
            FeatureRow(icon: "location.fill",        text: "Manual region selection when available on supported plans")
            FeatureRow(icon: "iphone.and.arrow.forward", text: "Up to 5 simultaneous devices")
        }
        .padding(KFSpacing.md)
        .kfCard()
    }

    private var productPicker: some View {
        VStack(spacing: KFSpacing.sm) {
            if storeKit.isLoading && storeKit.products.isEmpty {
                ProgressView()
                    .tint(Color.kfAccentBlue)
                    .frame(height: 120)
            } else {
                ForEach(storeKit.products, id: \.id) { product in
                    ProductOptionView(
                        product: product,
                        isSelected: selectedProductId == product.id,
                        isBestValue: product.id == WraithProduct.enclaveAnnual.rawValue
                    )
                    .onTapGesture { selectedProductId = product.id }
                }
            }
        }
    }

    private var ctaButton: some View {
        Button {
            guard let product = storeKit.products.first(where: { $0.id == selectedProductId }) else { return }
            Task { await storeKit.purchase(product) }
        } label: {
            Group {
                if storeKit.isLoading {
                    ProgressView().tint(.white)
                } else {
                    Text("Subscribe Now")
                        .font(KFFont.heading(18))
                        .foregroundStyle(.white)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, KFSpacing.md)
            .background(LinearGradient.kfAccent)
            .clipShape(Capsule())
        }
        .disabled(storeKit.isLoading)
        .shadow(color: Color.kfAccentPurple.opacity(0.25), radius: 24, y: 14)
    }

    private var freeTierButton: some View {
        VStack(spacing: KFSpacing.sm) {
            VStack(alignment: .leading, spacing: KFSpacing.xs) {
                Text("Start free")
                    .font(KFFont.heading(18))
                    .foregroundStyle(.white)
                Text("Haven DNS protects your DNS queries from ads and trackers at no cost. Upgrade to WraithVPN when you want full Enclave routing through WraithGates.")
                    .font(KFFont.body(14))
                    .foregroundStyle(Color.kfTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                onContinueFree?()
                if onContinueFree == nil {
                    dismiss()
                }
                } label: {
                VStack(spacing: 8) {
                    Text("Continue With Haven DNS Free")
                        .font(KFFont.heading(16))
                        .foregroundStyle(.white)
                    Text("Haven DNS blocks ads and trackers at the DNS level. Upgrade to WraithVPN for full Enclave routing.")
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

    private var legalFooter: some View {
        VStack(spacing: KFSpacing.xs) {
            HStack(spacing: KFSpacing.lg) {
                Button("Restore Purchase") {
                    Task { await storeKit.restorePurchases() }
                }
                .font(KFFont.caption(13))
                .foregroundStyle(Color.kfAccentBlue)

                Button("Have a token?") {
                    showTokenEntry = true
                }
                .font(KFFont.caption(13))
                .foregroundStyle(Color.kfAccentBlue)
            }
            .sheet(isPresented: $showTokenEntry) {
                TokenActivationSheet()
                    .environmentObject(storeKit)
            }

            Text("No account required. App Store subscribers can restore via Apple ID. Token-based subscribers recover using their original token or a registered recovery email. Payment will be charged to your Apple ID at confirmation of purchase. Subscriptions renew automatically unless cancelled at least 24 hours before the end of the current period.")
                .font(KFFont.caption(11))
                .foregroundStyle(Color.kfTextMuted)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
        }
    }
}

// MARK: - Feature row

private struct FeatureRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: KFSpacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(Color.kfAccentBlue)
                .frame(width: 20)
            Text(text)
                .font(KFFont.body(14))
                .foregroundStyle(Color.kfTextSecondary)
            Spacer()
        }
    }
}

// MARK: - Product option

private struct ProductOptionView: View {
    let product: Product
    let isSelected: Bool
    let isBestValue: Bool

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: KFSpacing.xs) {
                    Text(displayName)
                        .font(KFFont.heading(15))
                        .foregroundStyle(.white)
                    if isBestValue {
                        Text("BEST VALUE")
                            .font(KFFont.caption(10, weight: .bold))
                            .kerning(1)
                            .foregroundStyle(.black)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.kfConnected)
                            .clipShape(Capsule())
                    }
                }
                if isBestValue, let monthlyEquivalent {
                    Text("Just \(monthlyEquivalent)/mo — save ~33%")
                        .font(KFFont.caption(12))
                        .foregroundStyle(Color.kfTextMuted)
                }
            }
            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(product.displayPrice)
                    .font(KFFont.heading(16))
                    .foregroundStyle(.white)
                Text(periodLabel)
                    .font(KFFont.caption(11))
                    .foregroundStyle(Color.kfTextMuted)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(isSelected ? Color.kfAccentBlue : Color.kfTextMuted)
                    .padding(.top, 8)
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
                    isSelected
                        ? LinearGradient.kfAccent
                        : LinearGradient(colors: [Color.kfBorder], startPoint: .top, endPoint: .bottom),
                    lineWidth: isSelected ? 2 : 1
                )
        )
        .animation(.easeInOut(duration: 0.2), value: isSelected)
    }

    private var displayName: String {
        product.id == WraithProduct.enclaveAnnual.rawValue
            ? "WraithVPN — Annual"
            : "WraithVPN — Monthly"
    }

    private var periodLabel: String {
        product.id == WraithProduct.enclaveAnnual.rawValue ? "per year" : "per month"
    }

    private var monthlyEquivalent: String? {
        guard product.id == WraithProduct.enclaveAnnual.rawValue else { return nil }
        let monthly = product.price / 12
        return monthly.formatted(product.priceFormatStyle)
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        PaywallView()
            .environmentObject(StoreKitManager())
    }
}
