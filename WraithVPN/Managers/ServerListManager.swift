// ServerListManager.swift
// WraithVPN
//
// Fetches the server list, runs latency probes against each node,
// and publishes sorted results. Latency is measured via TCP connect
// to port 51820 (WireGuard) with a 3-second timeout per host.

import Foundation
import Network
import Combine

@MainActor
final class ServerListManager: ObservableObject {

    // MARK: - Published

    @Published var servers: [ServerLatency] = []
    @Published var isLoading: Bool = false
    @Published var error: String? = nil
    @Published var selectedServer: VPNServer? = nil

    // MARK: - Private

    // Probe port 22 (SSH) via TCP — it's open and accepting on all WraithGate nodes,
    // giving a real .ready RTT. Port 51820 is WireGuard/UDP so TCP probing it never connects,
    // and port 443 is typically DROP (no RST) on these nodes, causing full 3s timeouts.
    private let probePort: NWEndpoint.Port = 22
    private let probeTimeout: TimeInterval = 3.0

    // MARK: - Public

    func refresh() async {
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            let rawServers = try await APIClient.shared.fetchServers()
            // Show servers immediately (no latency yet)
            servers = rawServers.map { ServerLatency(server: $0, milliseconds: nil) }
            // Run latency probes concurrently
            await probeAll(rawServers)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Fetches nearest server and pre-selects it without blocking the full list.
    func preselectNearest() async {
        do {
            let nearest = try await APIClient.shared.fetchNearestServer()
            if selectedServer == nil {
                selectedServer = nearest
            }
        } catch {
            // Non-fatal — server list still works
        }
    }

    func selectServer(_ server: VPNServer) {
        selectedServer = server
    }

    // MARK: - Latency probing

    private func probeAll(_ rawServers: [VPNServer]) async {
        await withTaskGroup(of: (String, Double?).self) { group in
            for server in rawServers {
                group.addTask { [weak self] in
                    guard let self else { return (server.nodeId, nil) }
                    let ms = await self.probe(host: server.endpoints.primary)
                    return (server.nodeId, ms)
                }
            }

            var results: [String: Double?] = [:]
            for await (nodeId, ms) in group {
                results[nodeId] = ms
            }

            // Merge latency into server list and sort
            let updated = rawServers.map { srv in
                ServerLatency(server: srv, milliseconds: results[srv.nodeId] ?? nil)
            }
            servers = updated.sorted {
                switch ($0.milliseconds, $1.milliseconds) {
                case (let a?, let b?): return a < b
                case (.some, nil):     return true
                case (nil, .some):     return false
                case (nil, nil):       return false
                }
            }
        }
    }

    /// TCP connect to host:probePort, returns round-trip in milliseconds or nil on failure.
    private func probe(host: String) async -> Double? {
        // Strip any port suffix from the endpoint — we always probe on probePort (SSH).
        // e.g. "vpn-eu1.katafract.com:51820" → "vpn-eu1.katafract.com"
        var hostname = host
        if host.contains(":") {
            let parts = host.split(separator: ":", maxSplits: 1)
            hostname = String(parts[0])
        }

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(hostname),
            port: probePort
        )
        let params = NWParameters.tcp
        params.prohibitedInterfaceTypes = []
        let connection = NWConnection(to: endpoint, using: params)

        return await withCheckedContinuation { continuation in
            let start = Date()
            let finishLock = NSLock()
            nonisolated(unsafe) var finished = false
            nonisolated(unsafe) var timeout: DispatchWorkItem?

            @Sendable func finish(with result: Double?) {
                finishLock.lock()
                defer { finishLock.unlock() }

                guard !finished else { return }
                finished = true
                timeout?.cancel()

                if result == nil {
                    connection.cancel()
                }

                continuation.resume(returning: result)
            }

            timeout = DispatchWorkItem {
                finish(with: nil)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + probeTimeout, execute: timeout!)

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    // Full TCP connection established (port is open).
                    let ms = Date().timeIntervalSince(start) * 1000
                    connection.cancel()
                    finish(with: ms)
                case .failed(let error):
                    // ECONNREFUSED = server sent TCP RST — it's reachable, port just isn't open.
                    // That RST is a real round-trip, so we still have a valid latency sample.
                    let ms = Date().timeIntervalSince(start) * 1000
                    let isRefused: Bool
                    if case .posix(let code) = error, code == .ECONNREFUSED { isRefused = true }
                    else { isRefused = false }
                    finish(with: isRefused ? ms : nil)
                case .cancelled:
                    finish(with: nil)
                default:
                    break
                }
            }

            connection.start(queue: .global(qos: .utility))
        }
    }
}
