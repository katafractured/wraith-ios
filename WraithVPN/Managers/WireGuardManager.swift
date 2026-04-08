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
    @Published var isProvisioned: Bool = false
    @Published var isAutoProvisioning: Bool = false
    /// User's preference — persisted across launches. Distinct from the NE profile's
    /// isOnDemandEnabled, which is temporarily disabled on manual disconnect so iOS
    /// doesn't fight the user.
    @Published var autoConnectEnabled: Bool = UserDefaults.standard.object(forKey: "autoConnectEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "autoConnectEnabled")
    /// Whether to enable the OS-level kill switch (includeAllNetworks). When off, traffic
    /// still routes through WireGuard but iOS can fall back if the tunnel drops.
    @Published var tunnelMode: TunnelMode = TunnelMode(
        rawValue: UserDefaults.standard.string(forKey: "tunnelMode") ?? ""
    ) ?? .full
    /// Public exit IP of the connected server (set on provision, cleared on disconnect).
    @Published var exitIP: String? = nil
    /// Timestamp of when the tunnel last transitioned to .connected.
    @Published var connectedSince: Date? = nil

    // MARK: - Private

    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?
    private var previousStatus: VPNStatus = .disconnected
    private let tunnelBundleId = "com.katafract.wraith.tunnel"
    /// True while any provision/switch is in-flight. Guards against concurrent
    /// provisioning from autoProvisionIfNeeded + user-triggered connectToServer.
    private var isProvisioning = false
    /// Tracks the manager-load task so `autoProvisionIfNeeded` can await it
    /// before inspecting `isProvisioned`, preventing a race condition that
    /// causes spurious re-provisioning on launch.
    private var managerLoadTask: Task<Void, Never>?

    // MARK: - Init / lifecycle

    init() {
        managerLoadTask = Task { await loadOrCreateManager() }
        // Re-sync UI state whenever the app returns to the foreground.
        // NE may have reconnected the tunnel while the app was backgrounded/suspended;
        // this ensures connectedSince, status, and exitIP all reflect reality.
#if canImport(UIKit)
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.syncStatus() }
        }
#endif
    }

    deinit {
        if let obs = statusObserver   { NotificationCenter.default.removeObserver(obs) }
        if let obs = foregroundObserver { NotificationCenter.default.removeObserver(obs) }
    }

    // MARK: - Public interface

    /// Provisions to nearest server and installs profile if no peer exists yet.
    /// Called automatically after purchase/token entry and on app launch.
    func autoProvisionIfNeeded() async {
        // Claim the provisioning lock BEFORE awaiting the manager-load task.
        // Without this, connectToServer() can slip in while we're suspended on
        // `await managerLoadTask`, see isProvisioning==false, and both proceed
        // concurrently — creating duplicate peers.
        guard !isProvisioning,
              KeychainHelper.shared.readOptional(for: .subscriptionToken) != nil else { return }
        isProvisioning = true
        defer { isProvisioning = false; isAutoProvisioning = false }

        // Wait for the manager to finish loading from NE preferences so that
        // `isProvisioned` reflects reality before we check it.
        await managerLoadTask?.value
        guard !isProvisioned else { return }

        isAutoProvisioning = true
        do {
            let server = try await APIClient.shared.fetchNearestServer()
            try await provisionAndInstall(server: server)
        } catch {
            // Silent — user can still tap Connect to retry
        }
    }

    /// Provisions to a specific server, installs the profile, then connects.
    /// - Same node + existing peer: reconnects without touching the backend.
    /// - Different node + existing peer: atomic switch (no extra slot consumed).
    /// - No existing peer, or stale peer (404): fresh provision.
    func connectToServer(_ server: VPNServer) async throws {
        // Prevent concurrent provision/switch operations.
        guard !isProvisioning else { return }
        isProvisioning = true
        defer { isProvisioning = false }
        await stopAllActiveTunnels()
        status = .connecting

        let existingPeerId = activePeerId ?? KeychainHelper.shared.readOptional(for: .activePeerId)
        let existingNodeId = connectedServer?.nodeId ?? KeychainHelper.shared.readOptional(for: .activeNodeId)

        if let peerId = existingPeerId, let nodeId = existingNodeId {
            if nodeId == server.nodeId {
                // Same node — profile already installed, just reconnect.
            } else {
                // Different node — switch atomically. Fall back to fresh provision
                // if the source peer is already revoked or missing (e.g. after reinstall).
                do {
                    try await switchAndInstall(fromPeerId: peerId, server: server)
                } catch let error as APIError {
                    if case .httpError(let code, _) = error, code == 404 {
                        try await provisionAndInstall(server: server)
                    } else {
                        throw error
                    }
                }
            }
        } else {
            try await provisionAndInstall(server: server)
        }

        await applyOnDemand(autoConnectEnabled)
        try? await manager?.loadFromPreferences()
        try startTunnel()
    }

    /// Starts the already-installed VPN profile.
    func connect() async throws {
        guard isProvisioned else {
            status = .failed("No VPN profile installed.")
            return
        }
        await stopAllActiveTunnels()
        status = .connecting
        // Reload preferences so the manager reflects the latest saved profile,
        // then apply on-demand before starting. Running applyOnDemand as a
        // detached Task races with startTunnel; await it here instead.
        await applyOnDemand(autoConnectEnabled)
        // One extra load after the save so the connection object is fresh.
        try? await manager?.loadFromPreferences()
        do {
            try startTunnel()
        } catch let err as NEVPNError where err.code == .configurationInvalid {
            // Profile is stale (e.g. signing identity changed after rebuild,
            // or concurrent provision left the NE manager in an invalid state).
            // Remove the stale profile and re-provision to the nearest server.
            await removeProfile()
            isProvisioned = false
            activePeerId  = nil
            KeychainHelper.shared.delete(for: .activePeerId)
            let nearest = try await APIClient.shared.fetchNearestServer()
            try await provisionAndInstall(server: nearest)
            await applyOnDemand(autoConnectEnabled)
            try? await manager?.loadFromPreferences()
            try startTunnel()
        }
    }

    /// Disconnects the active tunnel.
    /// Temporarily disables on-demand so iOS doesn't immediately reconnect,
    /// while leaving the user's autoConnectEnabled preference intact.
    func disconnect() {
        status = .disconnecting
        manager?.connection.stopVPNTunnel()
        Task { await applyOnDemand(false) }
    }

    /// Persists the tunnel mode. If connected, reinstalls the existing profile with the
    /// updated includeAllNetworks flag and restarts the tunnel — no re-provisioning needed.
    func setTunnelMode(_ mode: TunnelMode) async {
        tunnelMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "tunnelMode")
        guard status == .connected,
              let mgr = manager,
              let proto = mgr.protocolConfiguration as? NETunnelProviderProtocol,
              let configText = proto.providerConfiguration?["wgConfig"] as? String,
              let server = connectedServer else { return }
        status = .connecting
        mgr.connection.stopVPNTunnel()
        // Poll until the tunnel actually disconnects (up to 2 s), then reinstall.
        // Fixed sleeps are unreliable; NE teardown time varies with system load.
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(100))
            let s = mgr.connection.status
            if s == .disconnected || s == .invalid { break }
        }
        try? await installProfile(configText: configText, server: server)
        await applyOnDemand(autoConnectEnabled)
        try? startTunnel()
    }

    /// Persists the auto-connect preference and updates the live NE profile.
    func setAutoConnect(_ enabled: Bool) async {
        autoConnectEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "autoConnectEnabled")
        await applyOnDemand(enabled)
    }

    /// Revokes the active peer from the backend and removes the local profile.
    func revokePeer() async {
        if let peerId = activePeerId ?? KeychainHelper.shared.readOptional(for: .activePeerId) {
            try? await APIClient.shared.deletePeer(peerId: peerId)
        }
        await removeProfile()
        KeychainHelper.shared.delete(for: .activePeerId)
        KeychainHelper.shared.delete(for: .wgAssignedIP)
        KeychainHelper.shared.delete(for: .wgExitIP)
        activePeerId    = nil
        assignedIP      = nil
        exitIP          = nil
        connectedSince  = nil
        connectedServer = nil
        isProvisioned   = false
        status          = .disconnected
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

    /// Provisions a peer for the given server, installs the NE profile. Does not connect.
    private func provisionAndInstall(server: VPNServer) async throws {
        let pubkey    = try ensureKeypair()
        let label     = "WraithVPN-\(UIDevice.current.name.prefix(20))"
        let provision = try await APIClient.shared.provisionPeer(
            pubkey: pubkey,
            region: server.region,
            nodeId: server.nodeId,
            label:  label
        )
        // The server only knows our public key, so the returned config has no private key.
        // Inject it from Keychain before handing the config to the tunnel extension.
        let config = try injectPrivateKey(into: provision.config)
        try await installProfile(configText: config, server: server)
        activePeerId    = provision.peerId
        assignedIP      = provision.assignedIpv4
        exitIP          = provision.exitIpv4 ?? (server.ipv4.isEmpty ? nil : server.ipv4)
        connectedServer = server
        isProvisioned   = true
        NotificationCenter.default.post(name: .vpnServerDidChange, object: nil)
        try? KeychainHelper.shared.save(provision.peerId,  for: .activePeerId)
        try? KeychainHelper.shared.save(provision.nodeId,  for: .activeNodeId)
        try? KeychainHelper.shared.save(server.region,     for: .activeRegion)
        if let ip = provision.assignedIpv4.isEmpty ? nil : Optional(provision.assignedIpv4) {
            try? KeychainHelper.shared.save(ip, for: .wgAssignedIP)
        }
        if let ip = exitIP { try? KeychainHelper.shared.save(ip, for: .wgExitIP) }
    }

    /// Switches an existing peer to a new server node atomically (no extra slot consumed).
    private func switchAndInstall(fromPeerId: String, server: VPNServer) async throws {
        let pubkey    = try ensureKeypair()
        let label     = "WraithVPN-\(UIDevice.current.name.prefix(20))"
        let provision = try await APIClient.shared.switchPeer(
            fromPeerId: fromPeerId,
            pubkey:     pubkey,
            region:     server.region,
            nodeId:     server.nodeId,
            label:      label
        )
        let config = try injectPrivateKey(into: provision.config)
        try await installProfile(configText: config, server: server)
        activePeerId    = provision.peerId
        assignedIP      = provision.assignedIpv4
        exitIP          = provision.exitIpv4 ?? (server.ipv4.isEmpty ? nil : server.ipv4)
        connectedServer = server
        isProvisioned   = true
        NotificationCenter.default.post(name: .vpnServerDidChange, object: nil)
        try? KeychainHelper.shared.save(provision.peerId,  for: .activePeerId)
        try? KeychainHelper.shared.save(provision.nodeId,  for: .activeNodeId)
        try? KeychainHelper.shared.save(server.region,     for: .activeRegion)
        if !provision.assignedIpv4.isEmpty {
            try? KeychainHelper.shared.save(provision.assignedIpv4, for: .wgAssignedIP)
        }
        if let ip = exitIP { try? KeychainHelper.shared.save(ip, for: .wgExitIP) }
    }

    /// Replaces an empty/missing PrivateKey line in a wg-quick config with the
    /// key stored in the Keychain. Throws if no private key is available.
    private func injectPrivateKey(into config: String) throws -> String {
        guard let privKey = KeychainHelper.shared.readOptional(for: .wireguardPrivKey) else {
            throw WGError.noPrivateKey
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
            // No PrivateKey line at all — insert one right after [Interface]
            for (i, line) in lines.enumerated() {
                if line.trimmingCharacters(in: .whitespaces).lowercased() == "[interface]" {
                    lines.insert("PrivateKey = \(privKey)", at: i + 1)
                    break
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - NetworkExtension profile management

    private func loadOrCreateManager() async {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            if let existing = managers.first(where: {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?
                    .providerBundleIdentifier == tunnelBundleId
            }) {
                manager       = existing
                isProvisioned = true
                activePeerId  = KeychainHelper.shared.readOptional(for: .activePeerId)
                assignedIP    = KeychainHelper.shared.readOptional(for: .wgAssignedIP)
                exitIP        = KeychainHelper.shared.readOptional(for: .wgExitIP)
                // Restore which node this profile is provisioned for so server-change
                // detection works after an app restart.
                if let nodeId = KeychainHelper.shared.readOptional(for: .activeNodeId) {
                    let region = KeychainHelper.shared.readOptional(for: .activeRegion) ?? ""
                    connectedServer = VPNServer.stub(nodeId: nodeId, region: region)
                }
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
        // Full mode: OS-level kill switch — no internet if tunnel drops.
        // Standard mode: traffic routes through WireGuard but iOS can fall back.
        proto.includeAllNetworks = (tunnelMode == .full)
        proto.excludeLocalNetworks = true

        let onDemandRule = NEOnDemandRuleConnect()
        onDemandRule.interfaceTypeMatch = .any

        mgr.protocolConfiguration = proto
        mgr.localizedDescription  = "WraithVPN — \(server.cityName)"
        mgr.isEnabled             = true
        mgr.onDemandRules         = [onDemandRule]
        mgr.isOnDemandEnabled     = autoConnectEnabled

        try await mgr.saveToPreferences()
        // Reload to pick up saved preferences (required before starting)
        try await mgr.loadFromPreferences()
    }

    /// Updates isOnDemandEnabled on the saved NE profile without touching the config.
    private func applyOnDemand(_ enabled: Bool) async {
        guard let mgr = manager else { return }
        do {
            try await mgr.loadFromPreferences()
            if enabled {
                let rule = NEOnDemandRuleConnect()
                rule.interfaceTypeMatch = .any
                mgr.onDemandRules = [rule]
            }
            mgr.isOnDemandEnabled = enabled
            try await mgr.saveToPreferences()
        } catch {}
    }

    private func removeProfile() async {
        guard let mgr = manager else { return }
        try? await mgr.removeFromPreferences()
        manager = nil
    }

    // MARK: - Tunnel start

    /// Stops every active VPN tunnel on the device (ours and any other app's)
    /// before starting ours. iOS silently ignores startTunnel while another
    /// tunnel is connected, so we must clear the field first.
    private func stopAllActiveTunnels() async {
        guard let allManagers = try? await NETunnelProviderManager.loadAllFromPreferences() else { return }
        var stopped = false
        for mgr in allManagers {
            let s = mgr.connection.status
            if s == .connected || s == .connecting {
                mgr.connection.stopVPNTunnel()
                stopped = true
            }
        }
        if stopped {
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

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
        case .invalid:
            status = .disconnected
            connectedSince = nil
        case .disconnected:
            status = .disconnected
            connectedSince = nil
        case .connecting:
            status = .connecting
            connectedSince = nil
        case .connected:
            if connectedSince == nil { connectedSince = connection.connectedDate ?? Date() }
            status = .connected
        case .reasserting:
            status = .connecting
        case .disconnecting:
            status = .disconnecting
            connectedSince = nil
        @unknown default:
            status = .disconnected
            connectedSince = nil
        }

        // Post notifications for VPN state changes
        if status == .connected && previousStatus != .connected {
            NotificationCenter.default.post(name: .vpnDidConnect, object: nil)
        }
        if status == .disconnected && previousStatus != .disconnected {
            NotificationCenter.default.post(name: .vpnDidDisconnect, object: nil)
        }
        previousStatus = status
    }
}

// MARK: - Errors

enum WGError: LocalizedError {
    case noTunnelSession
    case keypairGenerationFailed
    case noPrivateKey

    var errorDescription: String? {
        switch self {
        case .noTunnelSession:         return "No tunnel session available."
        case .keypairGenerationFailed: return "Could not generate WireGuard keypair."
        case .noPrivateKey:            return "WireGuard private key not found in Keychain."
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let vpnServerDidChange = Notification.Name("vpnServerDidChange")
    static let vpnDidConnect       = Notification.Name("vpnDidConnect")
    static let vpnDidDisconnect    = Notification.Name("vpnDidDisconnect")
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
