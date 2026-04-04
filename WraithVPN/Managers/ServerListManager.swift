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

    private let probePort: NWEndpoint.Port = 51820
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

    /// TCP connect to host:51820, returns round-trip in milliseconds or nil on failure.
    private func probe(host: String) async -> Double? {
        // Strip scheme if present (endpoint may be "host:port")
        var hostname = host
        var port = probePort
        if host.contains(":") {
            let parts = host.split(separator: ":", maxSplits: 1)
            hostname = String(parts[0])
            if let p = UInt16(parts.last ?? ""), let nwp = NWEndpoint.Port(rawValue: p) {
                port = nwp
            }
        }

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(hostname),
            port: port
        )
        let params = NWParameters.tcp
        params.prohibitedInterfaceTypes = []
        let connection = NWConnection(to: endpoint, using: params)

        return await withCheckedContinuation { continuation in
            let start = Date()
            var finished = false
            let finishLock = NSLock()
            var timeout: DispatchWorkItem?

            func finish(with result: Double?) {
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
                    let ms = Date().timeIntervalSince(start) * 1000
                    connection.cancel()
                    finish(with: ms)
                case .failed, .cancelled:
                    finish(with: nil)
                default:
                    break
                }
            }

            connection.start(queue: .global(qos: .utility))
        }
    }
}
