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
import Network
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
    @Published var autoConnectEnabled: Bool = UserDefaults.standard.bool(forKey: "autoConnectEnabled")
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
    /// True when the active tunnel is a multi-hop (Enclave+) connection.
    @Published var isMultiHop: Bool = false
    /// Which transport is currently carrying traffic (.wireguard or .shadowsocks).
    @Published var activeTransport: TransportMode = .wireguard
    /// User's persisted transport preference. .wireguard tries WG first with SS fallback.
    /// .shadowsocks forces SS without a WG attempt.
    @Published var transportPreference: TransportMode = TransportMode(
        rawValue: UserDefaults.standard.string(forKey: "transportPreference") ?? ""
    ) ?? .wireguard
    /// Entry node for the active multi-hop session (nil if single-hop).
    @Published var multiHopEntryServer: VPNServer? = nil
    /// Exit node for the active multi-hop session (same as connectedServer for multi-hop).
    @Published var multiHopExitServer: VPNServer? = nil

    // MARK: - Private

    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?
    private var backgroundObserver: NSObjectProtocol?
    private var lastBackgroundedAt: Date?
    /// Minimum background duration before a foreground check fires a Layer 2
    /// rebalance probe. Short enough to catch real idle windows (user put phone
    /// down, came back) while ignoring quick app switches.
    private let layer2MinBackgroundSeconds: TimeInterval = 30
    /// Rate-limit Layer 2 rebalance probes — don't hammer /v1/token/info on
    /// every foreground. One check per 10 minutes is plenty for a hint that
    /// server-side refreshes every reconcile tick.
    private let layer2MinProbeInterval: TimeInterval = 600
    private var lastLayer2ProbeAt: Date?
    private var previousStatus: VPNStatus = .disconnected
    private let tunnelBundleId = "com.katafract.wraith.tunnel"
    private let appGroupDefaults = UserDefaults(suiteName: "group.com.katafract.wraith")
    /// True while any provision/switch is in-flight. Published so the UI can
    /// disable the connect button and show a loading state during provisioning.
    @Published private(set) var isProvisioning = false
    /// Issue #5: Guards against rapid transport mode toggles queuing concurrent calls
    private var isTransportSwitching = false
    /// Tracks the manager-load task so `autoProvisionIfNeeded` can await it
    /// before inspecting `isProvisioned`, preventing a race condition that
    /// causes spurious re-provisioning on launch.
    private var managerLoadTask: Task<Void, Never>?
    /// Tracks the launch-time stale-peer verification task so `autoProvisionIfNeeded`
    /// can await its completion before inspecting `isProvisioned`.
    private var stalePeerCheckTask: Task<Void, Never>?
    /// Guards against re-provision loops when the network blocks UDP 51820.
    /// Resets to 0 on successful handshake or manual disconnect.
    private var reprovisionAttempts = 0
    private let maxReprovisionAttempts = 2
    /// Holds the current post-connect health check task so a rapid
    /// connect/disconnect/connect cycle cancels the stale check and only
    /// the most-recent stable connect runs the full suite.
    private var healthCheckTask: Task<Void, Never>?
    /// Holds the current in-flight connect operation (provisionAndInstall or connectToServer).
    /// Allows disconnect to cancel the connect Task and force immediate teardown.
    private var connectTask: Task<Void, Error>?
    /// Tracks whether we should engage SS fallback on the next .connected transition.
    /// Set by connectToServer() when transportPreference==.shadowsocks, cleared after
    /// engagement so it doesn't fire on every reconnect.
    private var pendingShadowsocksEngagement: Bool = false

    // MARK: - Phase E2.2 latency reporting + periodic Layer 2

    /// Tracks the client's current network class (wifi / cellular / wired /
    /// unknown) via NWPathMonitor. Sent with every latency report.
    private var currentNetClass: String = "unknown"
    private var networkMonitor: NWPathMonitor?
    /// Debounce — never fire a latency report more often than every 5 min even
    /// if multiple triggers stack (network change + foreground in quick succession).
    private let latencyReportMinInterval: TimeInterval = 300
    private var lastLatencyReportAt: Date?
    private var latencyReportTask: Task<Void, Never>?
    /// Periodic (30 min) background loop — fires latency reporting and Layer 2
    /// probes while foregrounded. Cancelled on deinit.
    private var periodicTask: Task<Void, Never>?

    // MARK: - Init / lifecycle

    init() {
        // Mock injection for screenshots
        if ScreenshotMode.mockConnected {
            status = .connected
            exitIP = "178.104.49.211"
            assignedIP = "10.10.1.14"
            connectedSince = Date(timeIntervalSinceNow: -222)
            connectedServer = VPNServer(nodeId: "nbg1", site: "nbg1", region: "de", displayName: "Frankfurt", ipv4: "178.104.49.211", ipv6: "fd10:0:1::1", endpoints: .init(primary: "nbg1.example.com", secondary: "178.104.49.211"), publicKey: "", wgPort: 51820, loadScore: 0.5, ipv6Available: true, geodnsWeight: 100)
            isMultiHop = false
        }
        if ScreenshotMode.mockDisconnectedAdvanced {
            status = .disconnected
            tunnelMode = .full
            UserDefaults.standard.set(false, forKey: "simpleMode")
        }

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
            Task { @MainActor [weak self] in
                self?.syncStatus()
                await self?.checkLayer2RebalanceOnForeground()
                self?.scheduleLatencyReport(reason: "foreground")
            }
        }
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.lastBackgroundedAt = Date()
            }
        }
#endif
        startNetworkMonitor()
        startPeriodicLoop()
    }

    deinit {
        if let obs = statusObserver   { NotificationCenter.default.removeObserver(obs) }
        if let obs = foregroundObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = backgroundObserver { NotificationCenter.default.removeObserver(obs) }
        networkMonitor?.cancel()
        latencyReportTask?.cancel()
        periodicTask?.cancel()
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
        await stalePeerCheckTask?.value
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
        // Cancel any prior connect Task and replace with this one so disconnect()
        // can cancel the operation if the user taps disconnect while connecting.
        connectTask?.cancel()

        // Prevent concurrent provision/switch operations.
        guard !isProvisioning else { return }
        isProvisioning = true
        defer { isProvisioning = false }
        await stopAllActiveTunnels()
        status = .connecting

        // Switching from multi-hop to single-hop: revoke both multi-hop peers and
        // clear all local state so we provision a clean single-hop peer below.
        // Without this, switchFromAnyExistingOrProvision picks the entry peer (wrong
        // node) and the exit peer ends up orphaned on the server with AllowedIPs=(none).
        if isMultiHop {
            await revokeAllPeers()
        }

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

        // Issue #7: Ensure activeTransport reflects the attempt — if not engaging SS,
        // explicitly set wireguard so stale .shadowsocks values don't persist.
        if transportPreference != .shadowsocks || appGroupDefaults?.data(forKey: "activeShadowsocksConfig") == nil {
            self.activeTransport = .wireguard
            pendingShadowsocksEngagement = false
        }

        // Issue #3: Honor transportPreference on fresh connect
        // Set a flag so syncStatus() will engage SS once the tunnel reaches .connected.
        // This avoids the race where startTunnel() only submits the request; the NE
        // extension isn't ready for IPC yet.
        if transportPreference == .shadowsocks, appGroupDefaults?.data(forKey: "activeShadowsocksConfig") != nil {
            pendingShadowsocksEngagement = true
        }
    }

    /// Phase F — region-first connect.
    ///
    /// Hands the picked region to the server, which selects the best node inside
    /// that region (sticky-region HARD rule: never crosses to another region).
    /// `preferredNodeId` is an optional hint honored only when in-region — used by
    /// the Layer 2 rebalance path.
    func connectToRegion(_ regionId: String, preferredNodeId: String? = nil) async throws {
        // Cancel any prior connect Task so disconnect() can cancel the operation.
        connectTask?.cancel()

        guard !isProvisioning else { return }
        isProvisioning = true
        defer { isProvisioning = false }
        await stopAllActiveTunnels()
        status = .connecting

        if isMultiHop {
            await revokeAllPeers()
            // Clear multi-hop state entirely when switching to single region
            KeychainHelper.shared.delete(for: .multiHopGroupId)
            KeychainHelper.shared.delete(for: .multiHopEntryPeerId)
            KeychainHelper.shared.delete(for: .multiHopExitPeerId)
            KeychainHelper.shared.delete(for: .multiHopEntryNodeId)
            KeychainHelper.shared.delete(for: .multiHopExitNodeId)
            KeychainHelper.shared.delete(for: .multiHopEntryRegion)
            KeychainHelper.shared.delete(for: .multiHopExitRegion)
            isMultiHop = false
            multiHopEntryServer = nil
            multiHopExitServer = nil
        }

        // Servers list gives us endpoint metadata for the NE profile install step.
        let allServers = (try? await APIClient.shared.fetchServers()) ?? []

        let pubkey = try ensureKeypair()
        let label  = "WraithVPN-\(UIDevice.current.name.prefix(20))"

        let existingPeerId = activePeerId ?? KeychainHelper.shared.readOptional(for: .activePeerId)
        let provision: ProvisionResponse
        if let fromPeerId = existingPeerId {
            do {
                provision = try await APIClient.shared.switchPeer(
                    fromPeerId: fromPeerId,
                    pubkey:     pubkey,
                    regionId:   regionId,
                    nodeId:     preferredNodeId,
                    label:      label
                )
            } catch let error as APIError {
                if case .httpError(let code, _) = error, code == 404 {
                    KeychainHelper.shared.delete(for: .activePeerId)
                    KeychainHelper.shared.delete(for: .activeNodeId)
                    provision = try await APIClient.shared.provisionPeer(
                        pubkey: pubkey, regionId: regionId, nodeId: preferredNodeId, label: label)
                } else { throw error }
            }
        } else {
            provision = try await APIClient.shared.provisionPeer(
                pubkey: pubkey, regionId: regionId, nodeId: preferredNodeId, label: label)
        }

        // Resolve the returned nodeId to a full VPNServer so installProfile has
        // endpoint / displayName metadata. Falls back to a stub if the node was
        // added between list fetch and provision.
        let server = allServers.first(where: { $0.nodeId == provision.nodeId })
            ?? VPNServer.stub(nodeId: provision.nodeId, region: regionId)

        let config = try injectPrivateKey(into: provision.config)
        try await installProfile(configText: config, server: server)

        activePeerId    = provision.peerId
        assignedIP      = provision.assignedIpv4
        exitIP          = provision.exitIpv4 ?? (server.ipv4.isEmpty ? nil : server.ipv4)
        connectedServer = server
        isProvisioned   = true
        NotificationCenter.default.post(name: .vpnServerDidChange, object: nil)
        do {
            try KeychainHelper.shared.save(provision.peerId, for: .activePeerId)
            try KeychainHelper.shared.save(provision.nodeId, for: .activeNodeId)
            try KeychainHelper.shared.save(regionId,         for: .activeRegion)
            if !provision.assignedIpv4.isEmpty {
                try KeychainHelper.shared.save(provision.assignedIpv4, for: .wgAssignedIP)
            }
            if let ip = exitIP { try KeychainHelper.shared.save(ip, for: .wgExitIP) }
        } catch {
            // A silent Keychain save failure is exactly how orphan profiles are born:
            // NE profile installs successfully but peerId never makes it to Keychain,
            // so the next launch loads the profile with peerId=nil and the user has
            // to manually reset the VPN config. Surface this so we can see it.
            DebugLogger.shared.peer("CRITICAL: Keychain save failed for peerId=\(provision.peerId): \(error.localizedDescription)")
        }
        DebugLogger.shared.peer("Region connect: region=\(regionId) → node=\(provision.nodeId) peer=\(provision.peerId)")

        await applyOnDemand(autoConnectEnabled)
        try? await manager?.loadFromPreferences()
        try startTunnel()
    }

    /// Foreground-triggered Layer 2 probe. Called when the app returns from
    /// background after a meaningful idle gap (≥ `layer2MinBackgroundSeconds`).
    /// Fetches a fresh `/v1/token/info`, reads the `preferredNode` hint, and
    /// passes it to `applyPreferredNodeIfIdle`. Rate-limited to at most one
    /// probe per `layer2MinProbeInterval` regardless of app-switch cadence.
    ///
    /// Why app-foreground and not a periodic timer: the idle window we want is
    /// "user wasn't actively using the tunnel" — a foregrounding after ≥30s in
    /// background is a strong proxy (phone was down / screen off), and riding
    /// the existing foreground observer avoids adding a background task.
    private func checkLayer2RebalanceOnForeground() async {
        // Meaningful idle gap: either we were backgrounded for long enough, or
        // we have no background timestamp yet (first foreground after launch).
        if let bg = lastBackgroundedAt {
            guard Date().timeIntervalSince(bg) >= layer2MinBackgroundSeconds else { return }
        }
        await performLayer2Probe()
    }

    /// Core Layer 2 probe — guarded by connection state and the per-probe
    /// rate limit. Called from the foreground observer (after an idle gap
    /// check) and from the periodic 30 min loop.
    private func performLayer2Probe() async {
        guard isProvisioned, !isProvisioning, !isMultiHop else { return }
        guard case .connected = status else { return }

        if let last = lastLayer2ProbeAt,
           Date().timeIntervalSince(last) < layer2MinProbeInterval {
            return
        }
        lastLayer2ProbeAt = Date()

        guard let token = KeychainHelper.shared.readOptional(for: .subscriptionToken) else { return }
        let info: TokenInfoResponse
        do {
            info = try await APIClient.shared.validateToken(token)
        } catch {
            DebugLogger.shared.peer("Layer2 probe: validateToken failed — \(error)")
            return
        }
        guard let hint = info.preferredNode else { return }
        DebugLogger.shared.peer("Layer2 probe: hint received → \(hint.nodeId) (\(hint.reason))")
        await applyPreferredNodeIfIdle(hint)
    }

    // MARK: - Phase E2.2 latency reporting

    /// Starts observing the client's current network interface class so every
    /// latency report tags the right bucket (wifi / cellular / wired). Also
    /// fires a debounced report on every path transition.
    private func startNetworkMonitor() {
        let monitor = NWPathMonitor()
        networkMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let newClass: String
            if path.usesInterfaceType(.wifi) {
                newClass = "wifi"
            } else if path.usesInterfaceType(.cellular) {
                newClass = "cellular"
            } else if path.usesInterfaceType(.wiredEthernet) {
                newClass = "wired"
            } else {
                newClass = "unknown"
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let changed = self.currentNetClass != newClass
                self.currentNetClass = newClass
                if changed {
                    self.scheduleLatencyReport(reason: "net-change")
                }
            }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
    }

    /// Periodic 30 min loop — fires both a latency report and a Layer 2 probe.
    /// Lives for the lifetime of this manager; individual triggers self-gate
    /// on token presence, connection state, and rate limits.
    private func startPeriodicLoop() {
        periodicTask?.cancel()
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30 * 60 * 1_000_000_000)
                guard let self else { return }
                await self.runLatencyReport()
                await self.performLayer2Probe()
            }
        }
    }

    /// Debounced wrapper around `runLatencyReport` — collapses rapid triggers
    /// (network change + foreground in quick succession) into a single probe.
    private func scheduleLatencyReport(reason: String) {
        latencyReportTask?.cancel()
        latencyReportTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5 s debounce
            guard let self, !Task.isCancelled else { return }
            DebugLogger.shared.api("LatencyProbe trigger: \(reason)")
            await self.runLatencyReport()
        }
    }

    /// Fetches the server list, probes one representative node per region via
    /// TCP port 22 (median of 3 samples), and POSTs results to
    /// `/v1/latency/report`. Silent failure; selector does not yet consume
    /// this data — E2.2 is the data-collection phase.
    private func runLatencyReport() async {
        guard KeychainHelper.shared.readOptional(for: .subscriptionToken) != nil else { return }
        if let last = lastLatencyReportAt,
           Date().timeIntervalSince(last) < latencyReportMinInterval {
            return
        }
        lastLatencyReportAt = Date()

        guard let servers = try? await APIClient.shared.fetchServers(), !servers.isEmpty else { return }
        let regionToMs = await LatencyProbe.probeRegions(from: servers)
        guard !regionToMs.isEmpty else { return }
        let netClass = currentNetClass
        let samples = regionToMs.map {
            LatencySample(regionId: $0.key, medianMs: $0.value, netClass: netClass)
        }
        await APIClient.shared.reportLatency(samples)
    }

    /// Layer 2 silent rebalance. Consumes a `PreferredNodeHint` returned by
    /// `/v1/token/info` and migrates the tunnel to the suggested node — but only
    /// when safe: same region (sticky rule), single-hop, already connected, no
    /// provision already in flight. Failures are logged and swallowed (hint is
    /// advisory, not mandatory).
    func applyPreferredNodeIfIdle(_ hint: PreferredNodeHint) async {
        guard isProvisioned,
              !isProvisioning,
              !isMultiHop,
              connectedServer?.region == hint.region,
              connectedServer?.nodeId != hint.nodeId
        else { return }
        guard case .connected = status else { return }
        do {
            DebugLogger.shared.peer("Layer2 rebalance: \(connectedServer?.nodeId ?? "?") → \(hint.nodeId) (\(hint.reason))")
            try await connectToRegion(hint.region, preferredNodeId: hint.nodeId)
        } catch {
            DebugLogger.shared.peer("Layer2 rebalance failed: \(error)")
        }
    }

    /// Provisions a multi-hop (Enclave+) tunnel to the given entry and exit nodes,
    /// installs the profile, then connects.
    func connectMultiHop(entry: VPNServer, exit: VPNServer) async throws {
        // Cancel any prior connect Task so disconnect() can cancel the operation.
        connectTask?.cancel()

        guard !isProvisioning else { return }
        isProvisioning = true
        defer { isProvisioning = false }

        await stopAllActiveTunnels()
        status = .connecting

        // Revoke any existing single-hop or multi-hop peers before provisioning new ones.
        await revokeAllPeers()

        let pubkey = try ensureKeypair()
        let label  = "WraithVPN-\(UIDevice.current.name.prefix(20))"
        let provision = try await APIClient.shared.provisionMultiHop(
            pubkey:      pubkey,
            entryNodeId: entry.nodeId,
            exitNodeId:  exit.nodeId,
            label:       label
        )

        let config = try injectPrivateKey(into: provision.config)
        // Use exit server as the "connected server" for display purposes (that's the exit IP).
        try await installProfile(configText: config, server: exit)

        // Persist multi-hop metadata.
        isMultiHop          = true
        multiHopEntryServer = entry
        multiHopExitServer  = exit
        connectedServer     = exit
        assignedIP          = provision.assignedIpv4
        exitIP              = exit.ipv4.isEmpty ? nil : exit.ipv4
        isProvisioned       = true

        try? KeychainHelper.shared.save(provision.hopGroupId,   for: .multiHopGroupId)
        try? KeychainHelper.shared.save(provision.entryPeerId,  for: .multiHopEntryPeerId)
        try? KeychainHelper.shared.save(provision.exitPeerId,   for: .multiHopExitPeerId)
        try? KeychainHelper.shared.save(provision.entryNodeId,  for: .multiHopEntryNodeId)
        try? KeychainHelper.shared.save(provision.exitNodeId,   for: .multiHopExitNodeId)
        try? KeychainHelper.shared.save(entry.region,           for: .multiHopEntryRegion)
        try? KeychainHelper.shared.save(exit.region,            for: .multiHopExitRegion)
        if let ip = provision.assignedIpv4.isEmpty ? nil : Optional(provision.assignedIpv4) {
            try? KeychainHelper.shared.save(ip, for: .wgAssignedIP)
        }
        if let ip = exitIP { try? KeychainHelper.shared.save(ip, for: .wgExitIP) }
        NotificationCenter.default.post(name: .vpnServerDidChange, object: nil)
        DebugLogger.shared.peer("Multi-hop provisioned: entry=\(entry.cityName) exit=\(exit.cityName) ip=\(provision.assignedIpv4)")

        await applyOnDemand(autoConnectEnabled)
        try? await manager?.loadFromPreferences()
        try startTunnel()
    }

    /// Revokes ALL active peers (single-hop + multi-hop) for this device.
    private func revokeAllPeers() async {
        // Single-hop peer
        if let peerId = activePeerId ?? KeychainHelper.shared.readOptional(for: .activePeerId) {
            try? await APIClient.shared.deletePeer(peerId: peerId)
        }
        // Multi-hop entry peer
        if let peerId = KeychainHelper.shared.readOptional(for: .multiHopEntryPeerId) {
            try? await APIClient.shared.deletePeer(peerId: peerId)
        }
        // Multi-hop exit peer
        if let peerId = KeychainHelper.shared.readOptional(for: .multiHopExitPeerId) {
            try? await APIClient.shared.deletePeer(peerId: peerId)
        }
        clearPeerState()
    }

    private func clearPeerState() {
        KeychainHelper.shared.delete(for: .activePeerId)
        KeychainHelper.shared.delete(for: .activeNodeId)
        KeychainHelper.shared.delete(for: .activeRegion)
        KeychainHelper.shared.delete(for: .wgAssignedIP)
        KeychainHelper.shared.delete(for: .wgExitIP)
        KeychainHelper.shared.delete(for: .multiHopGroupId)
        KeychainHelper.shared.delete(for: .multiHopEntryPeerId)
        KeychainHelper.shared.delete(for: .multiHopExitPeerId)
        KeychainHelper.shared.delete(for: .multiHopEntryNodeId)
        KeychainHelper.shared.delete(for: .multiHopExitNodeId)
        KeychainHelper.shared.delete(for: .multiHopEntryRegion)
        KeychainHelper.shared.delete(for: .multiHopExitRegion)
        activePeerId        = nil
        assignedIP          = nil
        exitIP              = nil
        connectedSince      = nil
        connectedServer     = nil
        isMultiHop          = false
        multiHopEntryServer = nil
        multiHopExitServer  = nil
        isProvisioned       = false
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
            // Do NOT clear Keychain peerId until the new provision succeeds —
            // otherwise a failed provision leaves an orphan profile + nil peerId
            // state that the load-time orphan guard would only heal on next launch.
            // provisionAndInstall overwrites Keychain on success.
            await removeProfile()
            isProvisioned = false
            let nearest = try await APIClient.shared.fetchNearestServer()
            try await provisionAndInstall(server: nearest)
            await applyOnDemand(autoConnectEnabled)
            try? await manager?.loadFromPreferences()
            try startTunnel()
        }
    }

    /// Sets status to .connecting immediately — call this before async API fetches
    /// that precede connectToServer() so the UI responds without delay.
    func setConnectingState() {
        guard status != .connecting && status != .connected else { return }
        status = .connecting
    }

    /// Disconnects the active tunnel.
    /// Cancels any in-flight connect Task and forces immediate teardown.
    /// Temporarily disables on-demand so iOS doesn't immediately reconnect,
    /// while leaving the user's autoConnectEnabled preference intact.
    func disconnect() {
        reprovisionAttempts = 0
        status = .disconnecting

        // Cancel any in-flight connect Task (provision/switch) so the UI responds immediately
        connectTask?.cancel()
        connectTask = nil

        let session = tunnelProviderSession
        // Disable OnDemand BEFORE stopping — if we stop first, iOS fires the
        // OnDemand rule immediately and reconnects before applyOnDemand finishes.
        Task {
            await TelemetryManager.shared.sessionEnded(connection: session)
            await applyOnDemand(false)
            manager?.connection.stopVPNTunnel()
        }
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

    /// Changes the transport mode preference and reconnects if currently connected.
    /// When switching to .shadowsocks (Stealth), uses the fallback transport.
    /// When switching to .wireguard, reconnects to re-try plain WG with fallback available.
    func setTransportMode(_ mode: TransportMode) async {
        // Issue #5: Guard against rapid toggles queuing concurrent calls
        guard !isTransportSwitching else { return }
        isTransportSwitching = true
        defer { isTransportSwitching = false }

        // Persist the preference immediately so the UI reflects it
        transportPreference = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "transportPreference")

        // Only reconnect if the tunnel is already up and connected
        guard case .connected = status, isProvisioned else {
            // Not connected — preference is saved, will take effect on next connect
            return
        }

        DebugLogger.shared.wg("Transport mode change requested: \(mode.rawValue)")

        // If switching to Shadowsocks, attempt the fallback transport immediately
        if mode == .shadowsocks {
            await attemptShadowsocksFallback()
            return
        }

        // If switching to WireGuard, reconnect by dropping and restarting the tunnel.
        // This gives WireGuard priority but keeps SS available as fallback if UDP is blocked.
        DebugLogger.shared.wg("Reconnecting to try WireGuard transport…")
        manager?.connection.stopVPNTunnel()
        // Issue #2: Poll until disconnected instead of fixed sleep (NE teardown is load-dependent)
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(100))
            let s = manager?.connection.status
            if s == .disconnected || s == .invalid { break }
        }
        try? startTunnel()

        // Issue #7: Reset activeTransport to wireguard after successful reconnect
        self.activeTransport = .wireguard
    }

    /// Revokes all active peers (single-hop or multi-hop) and removes the local profile.
    func revokePeer() async {
        await revokeAllPeers()
        await removeProfile()
        status = .disconnected
    }

    // MARK: - Post-connect health check

    /// Runs DNS + handshake tests after the tunnel reports connected.
    /// If the tunnel is dead (peer revoked, no handshake), automatically
    /// re-provisions to the nearest server.
    private func postConnectHealthCheck() async {
        // Wait 2 seconds for the WG handshake to complete.
        // Use Task.sleep so cancellation propagates if a newer connect fires.
        try? await Task.sleep(for: .milliseconds(2000))
        // If this task was superseded by a newer connect cycle, bail out.
        guard !Task.isCancelled, status == .connected else { return }

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

        if !report.needsReprovision {
            // Tunnel is healthy — reset the counter so a future failure
            // gets the full two attempts rather than a depleted count.
            // NOTE: this is the ONLY place we reset. .connected NE events
            // do NOT reset because NE connected ≠ WG handshake succeeded.
            reprovisionAttempts = 0
            if let server = connectedServer, let session = tunnelProviderSession {
                TelemetryManager.shared.sessionStarted(nodeId: server.nodeId, connection: session)
            }
            return
        }

        TelemetryManager.shared.recordHandshakeFailure()

        // Tunnel is dead — try to reprovision (max 2 attempts per connect session).
        guard reprovisionAttempts < maxReprovisionAttempts else {
            DebugLogger.shared.wg("Reprovision limit reached (\(maxReprovisionAttempts)). Network may be blocking UDP 51820.")
            status = .failed("VPN tunnel blocked. Try switching to cellular or a different network.")
            return
        }
        // Claim the provisioning lock BEFORE the first await so a
        // concurrent health-check task that also passed the sleep
        // will see isProvisioning=true and bail. With @MainActor the
        // check+set is atomic between suspension points.
        guard !isProvisioning else {
            DebugLogger.shared.wg("Health check: reprovision already in progress, skipping.")
            return
        }
        isProvisioning = true
        defer { isProvisioning = false }
        reprovisionAttempts += 1

        // Attempt 1: try Shadowsocks fallback if a config is available; otherwise
        // fall back to the original soft-reconnect path (restart tunnel, same peer).
        if reprovisionAttempts == 1 {
            if appGroupDefaults?.data(forKey: "activeShadowsocksConfig") != nil {
                DebugLogger.shared.wg("Health check FAILED: UDP blocked — attempting SS fallback (attempt 1/\(maxReprovisionAttempts))...")
                await attemptShadowsocksFallback()
                return
            }
            DebugLogger.shared.wg("Health check FAILED: trying soft reconnect (attempt 1/\(maxReprovisionAttempts))...")
            manager?.connection.stopVPNTunnel()
            try? await Task.sleep(for: .milliseconds(1500))
            try? startTunnel()
            // The next .connected event triggers another health check.
            // If it still fails, reprovisionAttempts will be 2 → full reprovision.
            return
        }

        // Attempt 2+: full reprovision (peer revoked or server unreachable)
        TelemetryManager.shared.recordReprovision()
        DebugLogger.shared.wg("Health check FAILED: soft reconnect insufficient. Full reprovision (attempt \(reprovisionAttempts)/\(maxReprovisionAttempts))...")

        // Tear down the dead tunnel and re-provision.
        // Do NOT clear Keychain peerId/nodeId here — provisionAndInstall overwrites
        // them on success. Clearing eagerly leaves an orphan-state combination
        // (NE profile present, Keychain peerId nil) when provision fails, which
        // forces the user to manually reset the VPN config.
        manager?.connection.stopVPNTunnel()
        try? await Task.sleep(for: .milliseconds(500))
        connectedServer = nil
        isProvisioned   = false

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

    // MARK: - Shadowsocks fallback

    /// Instructs the WireGuardTunnel extension to switch to Shadowsocks transport.
    /// The extension reads `activeShadowsocksConfig` from App Group UserDefaults and
    /// starts ShadowsocksTransport inline. Called when WG health check fails and a
    /// provisioned SS config is available.
    private func attemptShadowsocksFallback() async {
        guard let session = tunnelProviderSession else {
            DebugLogger.shared.wg("SS fallback: no tunnel session available")
            // Issue #8: Surface IPC failure to user
            status = .failed("Stealth unavailable — using direct WireGuard")
            transportPreference = .wireguard
            activeTransport = .wireguard
            return
        }
        // Message byte 1 = "switch to SS fallback"
        let message = Data([0x01])
        do {
            let reply = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
                try? session.sendProviderMessage(message) { data in
                    continuation.resume(returning: data)
                }
            }
            if let reply, reply.first == 0x01 {
                DebugLogger.shared.wg("SS fallback: extension confirmed transport switch")
                activeTransport = .shadowsocks
                status = .connected  // optimistic; will re-health-check on next cycle
            } else {
                DebugLogger.shared.wg("SS fallback: extension returned unexpected reply")
                // Issue #8: Surface unexpected reply to user
                status = .failed("Stealth unavailable — using direct WireGuard")
                transportPreference = .wireguard
                activeTransport = .wireguard
            }
        } catch {
            DebugLogger.shared.wg("SS fallback: sendProviderMessage error — \(error.localizedDescription)")
            // Issue #8: Surface IPC error to user
            status = .failed("Stealth unavailable — using direct WireGuard")
            transportPreference = .wireguard
            activeTransport = .wireguard
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
            regionId: server.region,
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
        do {
            try KeychainHelper.shared.save(provision.peerId, for: .activePeerId)
            try KeychainHelper.shared.save(provision.nodeId, for: .activeNodeId)
            try KeychainHelper.shared.save(server.region,    for: .activeRegion)
            if !provision.assignedIpv4.isEmpty {
                try KeychainHelper.shared.save(provision.assignedIpv4, for: .wgAssignedIP)
            }
            if let ip = exitIP { try KeychainHelper.shared.save(ip, for: .wgExitIP) }
        } catch {
            DebugLogger.shared.peer("CRITICAL: Keychain save failed for peerId=\(provision.peerId): \(error.localizedDescription)")
        }
        // Persist Shadowsocks fallback config + exit IP to App Group UserDefaults so the
        // WireGuardTunnel extension can read them without a Keychain access-group.
        if let ssConfig = provision.shadowsocksFallback,
           let encoded = try? JSONEncoder().encode(ssConfig) {
            appGroupDefaults?.set(encoded, forKey: "activeShadowsocksConfig")
        } else {
            appGroupDefaults?.removeObject(forKey: "activeShadowsocksConfig")
        }
        if let ip = exitIP {
            appGroupDefaults?.set(ip, forKey: "wgExitIP")
        }
        DebugLogger.shared.peer("Provisioned: peerId=\(provision.peerId) ip=\(provision.assignedIpv4) node=\(provision.nodeId) exit=\(exitIP ?? "nil")")
    }

    /// Switches an existing peer to a new server node atomically (no extra slot consumed).
    private func switchAndInstall(fromPeerId: String, server: VPNServer) async throws {
        let pubkey    = try ensureKeypair()
        let label     = "WraithVPN-\(UIDevice.current.name.prefix(20))"
        let provision = try await APIClient.shared.switchPeer(
            fromPeerId: fromPeerId,
            pubkey:     pubkey,
            regionId:   server.region,
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
        do {
            try KeychainHelper.shared.save(provision.peerId, for: .activePeerId)
            try KeychainHelper.shared.save(provision.nodeId, for: .activeNodeId)
            try KeychainHelper.shared.save(server.region,    for: .activeRegion)
            if !provision.assignedIpv4.isEmpty {
                try KeychainHelper.shared.save(provision.assignedIpv4, for: .wgAssignedIP)
            }
            if let ip = exitIP { try KeychainHelper.shared.save(ip, for: .wgExitIP) }
        } catch {
            DebugLogger.shared.peer("CRITICAL: Keychain save failed for peerId=\(provision.peerId) (switch): \(error.localizedDescription)")
        }
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
                // Restore multi-hop state so the route pill and IP display are correct
                // after an app restart while the NE tunnel is still running.
                if let entryNodeId = KeychainHelper.shared.readOptional(for: .multiHopEntryNodeId),
                   let exitNodeId  = KeychainHelper.shared.readOptional(for: .multiHopExitNodeId) {
                    isMultiHop = true
                    let entryRegion = KeychainHelper.shared.readOptional(for: .multiHopEntryRegion) ?? ""
                    let exitRegion  = KeychainHelper.shared.readOptional(for: .multiHopExitRegion)  ?? ""
                    multiHopEntryServer = VPNServer.stub(nodeId: entryNodeId, region: entryRegion)
                    multiHopExitServer  = VPNServer.stub(nodeId: exitNodeId,  region: exitRegion)
                    connectedServer     = multiHopExitServer
                } else if let nodeId = KeychainHelper.shared.readOptional(for: .activeNodeId) {
                    // Restore which node this profile is provisioned for so server-change
                    // detection works after an app restart.
                    let region = KeychainHelper.shared.readOptional(for: .activeRegion) ?? ""
                    connectedServer = VPNServer.stub(nodeId: nodeId, region: region)
                }
                DebugLogger.shared.ne("Loaded existing NE profile, peerId=\(activePeerId ?? "nil")")

                // Orphan-profile guard: NE profile exists but Keychain has no peerId
                // for either single-hop or multi-hop. This happens when a prior
                // provision/switch deleted the Keychain entry but the new provision
                // failed (e.g. backend 5xx) and left the dead NE profile installed.
                // Without this guard the app loops forever calling /peers/switch with
                // a nil source peer. Remove the orphan so autoProvisionIfNeeded fires
                // a fresh provision on next entry to ConnectView.
                let hasMultiHopState = KeychainHelper.shared.readOptional(for: .multiHopEntryPeerId) != nil
                if activePeerId == nil && !hasMultiHopState {
                    DebugLogger.shared.ne("Orphan NE profile (no peerId in Keychain). Removing and re-provisioning.")
                    await removeProfile()
                    isProvisioned   = false
                    connectedServer = nil
                    return
                }

                // Verify the peer is still active on the backend. If it was revoked
                // (all peers deleted, TTL reap, etc.) the NE profile is stale and
                // on-demand will start a tunnel that cannot handshake.
                if let peerId = activePeerId,
                   KeychainHelper.shared.readOptional(for: .subscriptionToken) != nil {
                    stalePeerCheckTask = Task {
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
        // 1. Stop any running tunnel (our own or other apps)
        await stopAllActiveTunnels()
        
        // 2. Try to load an existing manager WE own
        let existingOurs: NETunnelProviderManager?
        if let all = try? await NETunnelProviderManager.loadAllFromPreferences() {
            existingOurs = all.first { m in
                (m.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == tunnelBundleId
            }
        } else {
            existingOurs = nil
        }
        
        let mgr: NETunnelProviderManager
        if let existing = existingOurs {
            // In-place update — no re-approval prompt
            mgr = existing
        } else {
            // First install — fresh manager (iOS will show "Allow VPN Configuration")
            mgr = NETunnelProviderManager()
        }
        
        // 3. Build protocol config
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = tunnelBundleId
        proto.serverAddress = server.endpoints.primary
        proto.providerConfiguration = [
            "wgConfig": configText,
            "serverName": server.cityName,
        ]
        proto.includeAllNetworks = (tunnelMode == .full)
        proto.excludeLocalNetworks = true
        
        mgr.protocolConfiguration = proto
        mgr.localizedDescription = "WraithVPN — \(server.cityName)"
        mgr.isEnabled = true
        
        if autoConnectEnabled {
            let onDemandRule = NEOnDemandRuleConnect()
            onDemandRule.interfaceTypeMatch = .any
            mgr.onDemandRules = [onDemandRule]
            mgr.isOnDemandEnabled = true
        } else {
            mgr.onDemandRules = []
            mgr.isOnDemandEnabled = false
        }
        
        try await mgr.saveToPreferences()
        try await mgr.loadFromPreferences()
        self.manager = mgr
        observeStatus()
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
            // Do NOT reset reprovisionAttempts here — .connected just means the NE
            // extension started, NOT that the WG handshake succeeded. The health check
            // resets the counter when it confirms the tunnel is actually routing traffic.

            // Issue #3 fix: If we set transportPreference to .shadowsocks before connect,
            // engage the SS fallback now that the tunnel has reached .connected.
            if pendingShadowsocksEngagement {
                pendingShadowsocksEngagement = false
                Task { await self.attemptShadowsocksFallback() }
            }
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
            // Cancel any in-flight health check from a prior connect cycle
            // (rapid connect/disconnect/connect generates stale tasks).
            // Only the latest stable connect should run the suite.
            healthCheckTask?.cancel()
            healthCheckTask = Task { await postConnectHealthCheck() }
        }
        if status == .disconnected && previousStatus != .disconnected {
            NotificationCenter.default.post(name: .vpnDidDisconnect, object: nil)
            DebugLogger.shared.ne("Tunnel status -> disconnected")
            if let tunnelError = UserDefaults(suiteName: "group.com.katafract.wraith")?
                .string(forKey: "lastTunnelError") {
                DebugLogger.shared.ne("NE error: \(tunnelError)")
            }
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
