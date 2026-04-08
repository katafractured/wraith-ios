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
    ) ?? .standard
    /// Public exit IP of the connected server (set on provision, cleared on disconnect).
    @Published var exitIP: String? = nil
    /// Timestamp of when the tunnel last transitioned to .connected.
    @Published var connectedSince: Date? = nil
    /// Latest tunnel health report (populated after each connect).
    @Published var healthReport: TunnelHealthReport? = nil

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
    /// Guards against re-provision loops when the network blocks UDP 51820.
    /// Resets to 0 on successful handshake or manual disconnect.
    private var reprovisionAttempts = 0
    private let maxReprovisionAttempts = 2

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
                // Same node — renew the peer to confirm it still exists on the backend.
                // If renew returns false (peer was revoked), treat as stale and re-provision.
                let stillActive = await APIClient.shared.renewPeer(peerId: peerId)
                if !stillActive {
                    // Peer was deleted server-side (user removed it, TTL reap, etc.).
                    // Clear keychain so provisionAndInstall runs clean.
                    KeychainHelper.shared.delete(for: .activePeerId)
                    KeychainHelper.shared.delete(for: .activeNodeId)
                    try await switchFromAnyExistingOrProvision(server: server)
                }
            } else {
                // Different node — switch atomically. On 404 (stale keychain),
                // look up any existing peer for this device's pubkey before
                // falling back to a fresh provision — avoids orphaning a peer
                // that exists but isn't tracked in keychain.
                do {
                    try await switchAndInstall(fromPeerId: peerId, server: server)
                } catch let error as APIError {
                    if case .httpError(let code, _) = error, code == 404 {
                        try await switchFromAnyExistingOrProvision(server: server)
                    } else {
                        throw error
                    }
                }
            }
        } else {
            try await switchFromAnyExistingOrProvision(server: server)
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
        reprovisionAttempts = 0
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
        try? await manager?.loadFromPreferences()
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

    // MARK: - Post-connect health check

    /// Runs DNS + handshake tests after the tunnel reports connected.
    /// If the tunnel is dead (peer revoked, no handshake), automatically
    /// re-provisions to the nearest server.
    private func postConnectHealthCheck() async {
        // Wait 2 seconds for the WG handshake to complete
        try? await Task.sleep(for: .milliseconds(2000))
        guard status == .connected else { return }

        let havenIP: String? = {
            guard let assigned = assignedIP else { return nil }
            let parts = assigned.split(separator: ".")
            guard parts.count == 4 else { return nil }
            return "\(parts[0]).\(parts[1]).\(parts[2]).1"
        }()

        let report = await DNSHealthCheck.shared.runHealthCheck(
            havenDNSIP: havenIP,
            connection: tunnelProviderSession
        )
        healthReport = report

        if report.needsReprovision {
            guard reprovisionAttempts < maxReprovisionAttempts else {
                DebugLogger.shared.wg("Reprovision limit reached (\(maxReprovisionAttempts)). Network may be blocking UDP 51820.")
                status = .failed("VPN tunnel blocked. Try switching to cellular or a different network.")
                return
            }
            reprovisionAttempts += 1
            DebugLogger.shared.wg("Health check FAILED: tunnel dead. Auto-reprovisioning (attempt \(reprovisionAttempts)/\(maxReprovisionAttempts))...")

            // Tear down the dead tunnel and re-provision
            manager?.connection.stopVPNTunnel()
            try? await Task.sleep(for: .milliseconds(500))

            // Clear stale peer info
            KeychainHelper.shared.delete(for: .activePeerId)
            KeychainHelper.shared.delete(for: .activeNodeId)
            activePeerId = nil
            connectedServer = nil
            isProvisioned = false

            do {
                let nearest = try await APIClient.shared.fetchNearestServer()
                try await provisionAndInstall(server: nearest)
                await applyOnDemand(autoConnectEnabled)
                try? await manager?.loadFromPreferences()
                try startTunnel()
                DebugLogger.shared.wg("Auto-reprovision complete. Tunnel restarted.")
            } catch {
                DebugLogger.shared.wg("Auto-reprovision FAILED: \(error.localizedDescription)")
                status = .failed("Tunnel dead, re-provision failed: \(error.localizedDescription)")
            }
        }
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

    /// Checks the server for any active peer matching the current device pubkey.
    /// If one exists on a different node, switches from it (no extra slot consumed).
    /// Falls back to a fresh provision if no matching peer is found.
    /// Used as the 404-fallback path and for cases where keychain has no peer ID.
    private func switchFromAnyExistingOrProvision(server: VPNServer) async throws {
        // Look for any active peer on a different node — covers stale keychain
        // after restore, partial reinstall, or HA failback. Switch from it rather
        // than provisioning fresh (keeps slot count stable, no orphan left behind).
        if let peerList = try? await APIClient.shared.fetchPeers(),
           let match = peerList.peers.first(where: { $0.nodeId != server.nodeId }) {
            try await switchAndInstall(fromPeerId: match.peerId, server: server)
        } else {
            try await provisionAndInstall(server: server)
        }
    }

    /// Provisions a peer for the given server, installs the NE profile. Does not connect.
    private func provisionAndInstall(server: VPNServer) async throws {
        DebugLogger.shared.peer("Provisioning on node=\(server.nodeId) region=\(server.region)")
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
        DebugLogger.shared.peer("Provisioned: peerId=\(provision.peerId) ip=\(provision.assignedIpv4) node=\(provision.nodeId) exit=\(exitIP ?? "nil")")
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
                DebugLogger.shared.ne("Loaded existing NE profile, peerId=\(activePeerId ?? "nil")")

                // Verify the peer is still active on the backend. If it was revoked
                // (all peers deleted, TTL reap, etc.) the NE profile is stale and
                // on-demand will start a tunnel that cannot handshake.
                if let peerId = activePeerId,
                   KeychainHelper.shared.readOptional(for: .subscriptionToken) != nil {
                    Task {
                        let stillActive = await APIClient.shared.renewPeer(peerId: peerId)
                        if !stillActive {
                            DebugLogger.shared.peer("Stale peer detected on launch: \(peerId). Clearing profile.")
                            // Peer is gone -- clear local state so autoProvisionIfNeeded
                            // will fire and install a fresh config.
                            await removeProfile()
                            isProvisioned = false
                            activePeerId  = nil
                            KeychainHelper.shared.delete(for: .activePeerId)
                            KeychainHelper.shared.delete(for: .activeNodeId)
                        } else {
                            DebugLogger.shared.peer("Peer \(peerId) confirmed active on backend")
                        }
                    }
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

        // If the tunnel extension is running, stop it before installing a new config.
        // saveToPreferences() updates on-disk config but the running extension keeps
        // the OLD config in memory — startTunnel() on an active tunnel is a no-op.
        let currentStatus = mgr.connection.status
        if currentStatus == .connected || currentStatus == .connecting || currentStatus == .reasserting {
            mgr.connection.stopVPNTunnel()
            // Wait up to 3s for the extension to stop
            for _ in 0..<30 {
                try? await Task.sleep(for: .milliseconds(100))
                if mgr.connection.status == .disconnected { break }
            }
        }

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

    // MARK: - Tunnel session (for health checks)

    /// Exposes the NE tunnel session so DNSHealthCheck can send provider messages.
    var tunnelProviderSession: NETunnelProviderSession? {
        manager?.connection as? NETunnelProviderSession
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
            reprovisionAttempts = 0  // Successful connection — reset loop guard
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
            DebugLogger.shared.ne("Tunnel status -> connected")
            // Run post-connect health check after a brief delay to let the
            // WG handshake complete. If the health check detects a dead tunnel,
            // automatically re-provision.
            Task { await postConnectHealthCheck() }
        }
        if status == .disconnected && previousStatus != .disconnected {
            NotificationCenter.default.post(name: .vpnDidDisconnect, object: nil)
            DebugLogger.shared.ne("Tunnel status -> disconnected")
            healthReport = nil
        }
        if status == .connecting && previousStatus != .connecting {
            DebugLogger.shared.ne("Tunnel status -> connecting")
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
