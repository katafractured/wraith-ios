// DisconnectVPNIntent.swift
// WraithVPN
//
// App Intent: "Disconnect WraithVPN" — stops the tunnel without opening the app.

import AppIntents
import NetworkExtension

struct DisconnectVPNIntent: AppIntent {

    static var title: LocalizedStringResource = "Disconnect WraithVPN"
    static var description = IntentDescription(
        "Disconnect from WraithVPN.",
        categoryName: "VPN"
    )
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some ProvidesDialog {
        let tunnelId = "com.katafract.wraith.tunnel"
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()

        guard let mgr = managers.first(where: {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?
                .providerBundleIdentifier == tunnelId
        }) else {
            return .result(dialog: "WraithVPN is not connected.")
        }

        let status = mgr.connection.status
        guard status == .connected || status == .connecting || status == .reasserting else {
            return .result(dialog: "WraithVPN is already disconnected.")
        }

        mgr.connection.stopVPNTunnel()
        return .result(dialog: "WraithVPN disconnected.")
    }
}
