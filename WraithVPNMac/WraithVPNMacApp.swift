// WraithVPNMacApp.swift
// WraithVPNMac

import SwiftUI
import KatafractStyle

@main
struct WraithVPNMacApp: App {

    @StateObject private var storeKit = StoreKitManager()
    @StateObject private var vpn     = WireGuardManager()
    @StateObject private var servers = ServerListManager()
    @StateObject private var haven   = HavenDNSManager()

    var body: some Scene {
        // Main app window — shown on launch and from dock
        Window("WraithVPN", id: "main") {
            MacMainView()
                .environmentObject(storeKit)
                .environmentObject(vpn)
                .environmentObject(servers)
                .environmentObject(haven)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 440, height: 560)
        .windowStyle(.hiddenTitleBar)

        // Menubar quick-access popover
        MenuBarExtra {
            MainMenuView()
                .environmentObject(storeKit)
                .environmentObject(vpn)
                .environmentObject(servers)
                .environmentObject(haven)
        } label: {
            Image(systemName: menuBarIcon)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(menuBarTint)
        }
        .menuBarExtraStyle(.window)
        .tint(KataAccent.gold)

        Window("Account & Settings", id: "settings") {
            MacAccountView()
                .environmentObject(storeKit)
                .environmentObject(vpn)
                .environmentObject(haven)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 440, height: 520)
    }

    private var menuBarIcon: String {
        switch vpn.status {
        case .connected:               return "shield.fill"
        case .connecting, .disconnecting: return "shield.lefthalf.filled"
        default:                       return "shield"
        }
    }

    private var menuBarTint: Color {
        switch vpn.status {
        case .connected:               return .kfConnected
        case .connecting, .disconnecting: return .kfConnecting
        default:                       return .secondary
        }
    }
}
