import SwiftUI

@main
struct WraithVPNMacApp: App {

    @StateObject private var storeKit = StoreKitManager()
    @StateObject private var haven    = HavenDNSManager()

    var body: some Scene {
        MenuBarExtra("WraithVPN", systemImage: storeKit.hasPurchased ? "shield.lefthalf.filled" : "shield") {
            MenuBarView()
                .environmentObject(storeKit)
                .environmentObject(haven)
        }
        .menuBarExtraStyle(.window)
    }
}
