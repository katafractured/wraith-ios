// ContentView.swift
// WraithVPN
//
// Root view. Handles:
//   - Onboarding (shown once on first launch)
//   - Paywall gate (shown if no active subscription)
//   - Main app shell (ConnectView + NavigationStack)
//
// Environment objects are injected here and passed down via @EnvironmentObject.

import SwiftUI

struct ContentView: View {

    @EnvironmentObject var storeKit:  StoreKitManager
    @EnvironmentObject var vpn:       WireGuardManager
    @EnvironmentObject var servers:   ServerListManager
    @EnvironmentObject var haven:     HavenDNSManager

    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    @AppStorage("hasUnlockedFreeTier") private var hasUnlockedFreeTier = false

    // MARK: - Body

    var body: some View {
        Group {
            if storeKit.isCheckingEntitlements {
                // Checking keychain/StoreKit — hold here to prevent paywall flash
                ZStack {
                    Color.kfBackground.ignoresSafeArea()
                    Image("AppIcon-Display")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 80, height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                }
                .transition(.opacity)
            } else if !hasSeenOnboarding {
                OnboardingView {
                    withAnimation(.easeInOut(duration: 0.4)) {
                        hasSeenOnboarding = true
                    }
                }
                .transition(.asymmetric(
                    insertion: .opacity,
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
            } else if !storeKit.hasPurchased && !hasUnlockedFreeTier {
                NavigationStack {
                    PaywallView {
                        withAnimation(.easeInOut(duration: 0.35)) {
                            hasUnlockedFreeTier = true
                        }
                        Task { await haven.enable() }
                    }
                        .environmentObject(storeKit)
                }
                .transition(.opacity)
            } else {
                // Main app
                mainApp
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .opacity
                    ))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: storeKit.isCheckingEntitlements)
        .animation(.easeInOut(duration: 0.4), value: hasSeenOnboarding)
        .animation(.easeInOut(duration: 0.35), value: storeKit.hasPurchased)
        .animation(.easeInOut(duration: 0.35), value: hasUnlockedFreeTier)
        .task {
            await vpn.autoProvisionIfNeeded()
            await haven.ensureEnabledForSubscriber(hasPurchased: storeKit.hasPurchased || hasUnlockedFreeTier)
        }
        .onChange(of: storeKit.hasPurchased) { _, purchased in
            if purchased {
                Task {
                    await vpn.autoProvisionIfNeeded()
                    await haven.ensureEnabledForSubscriber(hasPurchased: true)
                }
            }
        }
    }

    // MARK: - Main app shell

    @ViewBuilder
    private var mainApp: some View {
        NavigationStack {
            ConnectView()
                .environmentObject(vpn)
                .environmentObject(servers)
                .navigationDestination(for: String.self) { route in
                    switch route {
                    case "settings":
                        SettingsView()
                            .environmentObject(storeKit)
                            .environmentObject(vpn)
                            .environmentObject(haven)
                    default:
                        EmptyView()
                    }
                }
        }
    }
}

// MARK: - Preview

#Preview {
    ContentView()
        .environmentObject(StoreKitManager())
        .environmentObject(WireGuardManager())
        .environmentObject(ServerListManager())
}
