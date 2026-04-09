// ConnectVPNIntent.swift
// WraithVPN
//
// App Intent: "Connect WraithVPN" — runs without opening the app.
// If already provisioned: starts the existing tunnel directly.
// If not provisioned: calls the API to provision on the nearest server, installs
// the NE profile, then starts the tunnel.

import AppIntents
import NetworkExtension
import CryptoKit
import Foundation

struct ConnectVPNIntent: AppIntent {

    static var title: LocalizedStringResource = "Connect WraithVPN"
    static var description = IntentDescription(
        "Connect to WraithVPN on the nearest server.",
        categoryName: "VPN"
    )
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some ProvidesDialog {
        guard KeychainHelper.shared.readOptional(for: .subscriptionToken) != nil else {
            throw VPNIntentError.notActivated
        }

        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        let tunnelId = "com.katafract.wraith.tunnel"

        if let mgr = managers.first(where: {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?
                .providerBundleIdentifier == tunnelId
        }) {
            // Already provisioned — just start the tunnel.
            let session = mgr.connection as? NETunnelProviderSession
            try session?.startTunnel(options: nil)
            let serverName = (mgr.protocolConfiguration as? NETunnelProviderProtocol)?
                .providerConfiguration?["serverName"] as? String ?? "nearest server"
            return .result(dialog: "Connected to \(serverName).")

        } else {
            // Not provisioned — provision on nearest server and install.
            let pubkey = try VPNIntentHelper.ensureKeypair()
            let nearest = try await APIClient.shared.fetchNearestServer()
            let label = "WraithVPN-Intent"
            let provision = try await APIClient.shared.provisionPeer(
                pubkey: pubkey,
                region: nearest.region,
                nodeId: nearest.nodeId,
                label: label
            )
            let config = try VPNIntentHelper.injectPrivateKey(into: provision.config)

            // Install NE profile
            let mgr = NETunnelProviderManager()
            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = tunnelId
            proto.serverAddress = nearest.endpoints.primary
            proto.providerConfiguration = [
                "wgConfig": config,
                "serverName": nearest.cityName,
            ]
            proto.includeAllNetworks = false
            proto.excludeLocalNetworks = true

            mgr.protocolConfiguration = proto
            mgr.localizedDescription   = "WraithVPN — \(nearest.cityName)"
            mgr.isEnabled              = true
            mgr.onDemandRules          = []
            mgr.isOnDemandEnabled      = false

            try await mgr.saveToPreferences()
            try await mgr.loadFromPreferences()

            // Persist peer info
            try? KeychainHelper.shared.save(provision.peerId, for: .activePeerId)
            try? KeychainHelper.shared.save(provision.nodeId, for: .activeNodeId)
            try? KeychainHelper.shared.save(nearest.region,  for: .activeRegion)
            if !provision.assignedIpv4.isEmpty {
                try? KeychainHelper.shared.save(provision.assignedIpv4, for: .wgAssignedIP)
            }

            let session = mgr.connection as? NETunnelProviderSession
            try session?.startTunnel(options: nil)
            return .result(dialog: "Connected to \(nearest.cityName).")
        }
    }
}

// MARK: - Errors

enum VPNIntentError: LocalizedError {
    case notActivated
    case noPrivateKey

    var errorDescription: String? {
        switch self {
        case .notActivated:  return "Open WraithVPN to activate your subscription first."
        case .noPrivateKey:  return "WireGuard key not found. Open WraithVPN to set up."
        }
    }
}

// MARK: - Shared helpers (intentionally lightweight, no ObservableObject)

enum VPNIntentHelper {

    /// Returns the existing WireGuard public key, or generates and stores a new keypair.
    static func ensureKeypair() throws -> String {
        if let existing = KeychainHelper.shared.readOptional(for: .wireguardPubKey) {
            return existing
        }
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let privBytes  = privateKey.rawRepresentation
        let pubBytes   = privateKey.publicKey.rawRepresentation
        let privB64    = privBytes.base64EncodedString()
        let pubB64     = pubBytes.base64EncodedString()
        try KeychainHelper.shared.save(privB64, for: .wireguardPrivKey)
        try KeychainHelper.shared.save(pubB64,  for: .wireguardPubKey)
        return pubB64
    }

    /// Injects the stored private key into a wg-quick config string.
    static func injectPrivateKey(into config: String) throws -> String {
        guard let privKey = KeychainHelper.shared.readOptional(for: .wireguardPrivKey) else {
            throw VPNIntentError.noPrivateKey
        }
        var lines = config.components(separatedBy: .newlines)
        var injected = false
        for (i, line) in lines.enumerated() {
            if line.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("privatekey") {
                lines[i] = "PrivateKey = \(privKey)"
                injected = true
                break
            }
        }
        if !injected {
            for (i, line) in lines.enumerated() {
                if line.trimmingCharacters(in: .whitespaces).lowercased() == "[interface]" {
                    lines.insert("PrivateKey = \(privKey)", at: i + 1)
                    break
                }
            }
        }
        return lines.joined(separator: "\n")
    }
}
