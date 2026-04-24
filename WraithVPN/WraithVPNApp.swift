// WraithVPNApp.swift
// WraithVPN
//
// App entry point. Creates the three long-lived ObservableObject singletons
// and injects them as environment objects so every view in the hierarchy can
// access them without needing explicit passing.

import SwiftUI
import KatafractStyle

@main
struct WraithVPNApp: App {

    // MARK: - App-wide state objects

    @StateObject private var storeKit = StoreKitManager()
    @StateObject private var vpn      = WireGuardManager()
    @StateObject private var servers  = ServerListManager()
    @StateObject private var haven    = HavenDNSManager()

    // MARK: - Scene

    init() {
        // Set simpleMode for screenshot modes
        if ScreenshotMode.mockDisconnectedAdvanced {
            UserDefaults.standard.set(false, forKey: "simpleMode")
        } else if ScreenshotMode.mockConnected {
            UserDefaults.standard.set(true, forKey: "simpleMode")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(storeKit)
                .environmentObject(vpn)
                .environmentObject(servers)
                .environmentObject(haven)
                // Force dark colour scheme app-wide; individual screens can override.
                .preferredColorScheme(.dark)
                .tint(KataAccent.gold)
        }
    }
}
