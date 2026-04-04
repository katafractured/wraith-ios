// WireGuardManager.swift
// WraithVPN
//
// Handles:
//   1. Curve25519 keypair generation (stored in Keychain)
//   2. Peer provisioning via APIClient
//   3. Installing / removing the WireGuard VPN profile via NetworkExtension
//   4. Toggling the tunnel on/off and observing connection status
//
// NOTE: NetworkExtension usage requires the com.apple.developer.networking.networkextension
// entitlement with the "packet-tunnel-provider" value, plus a separate Network Extension
// target (WireGuard tunnel provider). The tunnel binary is referenced by the bundle ID
// com.katafract.wraith.tunnel and must be included in the Xcode project.

import Foundation
import NetworkExtension
import Combine
import CryptoKit

// MARK: - Manager

@MainActor
final class WireGuardManager: ObservableObject {

    // MARK: - Published state

    @Published var status: VPNStatus = .disconnected
    @Published var connectedServer: VPNServer? = nil
    @Published var assignedIP: String? = nil
    @Published var activePeerId: String? = nil

    // MARK: - Private

    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?
    private let tunnelBundleId = "com.katafract.wraith.tunnel"

    // MARK: - Init / lifecycle

    init() {
        Task { await loadOrCreateManager() }
    }

    deinit {
        if let obs = statusObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    // MARK: - Public interface

    /// Main entry point. Generates keys if needed, provisions peer, installs profile, connects.
    func connectToServer(_ server: VPNServer) async throws {
        status = .connecting

        // 1. Ensure we have a keypair
        let pubkey = try ensureKeypair()

        // 2. Provision peer (or reuse existing one for this node)
        let provision = try await provisionPeer(pubkey: pubkey, server: server)

        // 3. Install / update VPN profile
        let configText = provision.config
        try await installProfile(configText: configText, server: server)

        // 4. Connect
        try startTunnel()

        activePeerId = provision.peerId
        assignedIP   = provision.assignedIpv4
        connectedServer = server

        // Persist peerId so we can revoke later
        try? KeychainHelper.shared.save(provision.peerId, for: .activePeerId)
    }

    /// Reconnects using the already-installed VPN profile (no provisioning needed).
    func connect() throws {
        guard manager != nil else {
            status = .failed("No VPN profile installed. Please connect to a server first.")
            return
        }
        status = .connecting
        try startTunnel()
    }

    /// Disconnects the active tunnel.
    func disconnect() {
        status = .disconnecting
        manager?.connection.stopVPNTunnel()
    }

    /// Revokes the active peer from the backend and removes the local profile.
    func revokePeer() async {
        if let peerId = activePeerId ?? KeychainHelper.shared.readOptional(for: .activePeerId) {
            try? await APIClient.shared.deletePeer(peerId: peerId)
        }
        await removeProfile()
        KeychainHelper.shared.delete(for: .activePeerId)
        activePeerId = nil
        assignedIP   = nil
        connectedServer = nil
        status = .disconnected
    }

    // MARK: - Keypair management

    /// Returns the existing public key, or generates + stores a new Curve25519 keypair.
    func ensureKeypair() throws -> String {
        if let existingPub = KeychainHelper.shared.readOptional(for: .wireguardPubKey) {
            return existingPub
        }
        return try generateKeypair()
    }

    @discardableResult
    func generateKeypair() throws -> String {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let privBytes  = privateKey.rawRepresentation
        let pubBytes   = privateKey.publicKey.rawRepresentation

        let privB64 = privBytes.base64EncodedString()
        let pubB64  = pubBytes.base64EncodedString()

        try KeychainHelper.shared.save(privB64, for: .wireguardPrivKey)
        try KeychainHelper.shared.save(pubB64,  for: .wireguardPubKey)

        return pubB64
    }

    // MARK: - Peer provisioning

    private func provisionPeer(pubkey: String, server: VPNServer) async throws -> ProvisionResponse {
        let label = "WraithVPN-\(UIDevice.current.name.prefix(20))"
        return try await APIClient.shared.provisionPeer(
            pubkey: pubkey,
            region: server.region,
            label: label
        )
    }

    // MARK: - NetworkExtension profile management

    private func loadOrCreateManager() async {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            if let existing = managers.first(where: {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?
                    .providerBundleIdentifier == tunnelBundleId
            }) {
                manager = existing
            } else {
                manager = NETunnelProviderManager()
            }
            observeStatus()
            syncStatus()
        } catch {
            status = .failed("Failed to load VPN preferences: \(error.localizedDescription)")
        }
    }

    private func installProfile(configText: String, server: VPNServer) async throws {
        guard let mgr = manager else { return }

        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = tunnelBundleId
        proto.serverAddress = server.endpoints.primary
        // Pass the WireGuard config to the tunnel extension via providerConfiguration
        proto.providerConfiguration = [
            "wgConfig": configText,
            "serverName": server.cityName,
        ]

        mgr.protocolConfiguration = proto
        mgr.localizedDescription  = "WraithVPN — \(server.cityName)"
        mgr.isEnabled             = true
        mgr.isOnDemandEnabled     = false

        try await mgr.saveToPreferences()
        // Reload to pick up saved preferences (required before starting)
        try await mgr.loadFromPreferences()
    }

    private func removeProfile() async {
        guard let mgr = manager else { return }
        try? await mgr.removeFromPreferences()
        manager = nil
    }

    // MARK: - Tunnel start

    private func startTunnel() throws {
        guard let connection = manager?.connection as? NETunnelProviderSession else {
            throw WGError.noTunnelSession
        }
        try connection.startTunnel(options: nil)
    }

    // MARK: - Status observation

    private func observeStatus() {
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: manager?.connection,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncStatus()
            }
        }
    }

    private func syncStatus() {
        guard let connection = manager?.connection else {
            status = .disconnected
            return
        }
        switch connection.status {
        case .invalid:       status = .disconnected
        case .disconnected:  status = .disconnected
        case .connecting:    status = .connecting
        case .connected:     status = .connected
        case .reasserting:   status = .connecting
        case .disconnecting: status = .disconnecting
        @unknown default:    status = .disconnected
        }
    }
}

// MARK: - Errors

enum WGError: LocalizedError {
    case noTunnelSession
    case keypairGenerationFailed

    var errorDescription: String? {
        switch self {
        case .noTunnelSession:       return "No tunnel session available."
        case .keypairGenerationFailed: return "Could not generate WireGuard keypair."
        }
    }
}

// MARK: - UIDevice shim for macOS Catalyst

#if canImport(UIKit)
import UIKit
#else
// On macOS without Catalyst, provide a stub so the file compiles.
import AppKit
private struct UIDevice {
    static let current = UIDevice()
    var name: String { Host.current().localizedName ?? "Mac" }
}
#endif
