// WraithVPNApp.swift
// WraithVPN
//
// App entry point. Creates the three long-lived ObservableObject singletons
// and injects them as environment objects so every view in the hierarchy can
// access them without needing explicit passing.

import SwiftUI

@main
struct WraithVPNApp: App {

    // MARK: - App-wide state objects

    @StateObject private var storeKit = StoreKitManager()
    @StateObject private var vpn      = WireGuardManager()
    @StateObject private var servers  = ServerListManager()

    // MARK: - Scene

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(storeKit)
                .environmentObject(vpn)
                .environmentObject(servers)
                // Force dark colour scheme app-wide; individual screens can override.
                .preferredColorScheme(.dark)
        }
    }
}
