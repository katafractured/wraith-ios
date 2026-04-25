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
        // Mock regions for screenshots
        if ScreenshotMode.mockRegions {
            let mockRegions = [
                VPNServer(nodeId: "nbg1", site: "nbg1", region: "de", displayName: "Frankfurt", ipv4: "178.104.49.211", ipv6: "fd10:0:1::1", endpoints: .init(primary: "nbg1.example.com", secondary: "178.104.49.211"), publicKey: "", wgPort: 51820, loadScore: 0.5, ipv6Available: true, geodnsWeight: 100),
                VPNServer(nodeId: "hel1", site: "hel1", region: "fi", displayName: "Helsinki", ipv4: "204.168.224.243", ipv6: "fd10:0:2::1", endpoints: .init(primary: "hel1.example.com", secondary: "204.168.224.243"), publicKey: "", wgPort: 51820, loadScore: 0.5, ipv6Available: true, geodnsWeight: 100),
                VPNServer(nodeId: "ash", site: "ash", region: "us", displayName: "Ashburn", ipv4: "87.99.128.159", ipv6: "fd10:0:6::1", endpoints: .init(primary: "ash.example.com", secondary: "87.99.128.159"), publicKey: "", wgPort: 51820, loadScore: 0.5, ipv6Available: true, geodnsWeight: 100),
                VPNServer(nodeId: "hil", site: "hil", region: "us", displayName: "Hillsboro", ipv4: "5.78.178.202", ipv6: "fd10:0:7::1", endpoints: .init(primary: "hil.example.com", secondary: "5.78.178.202"), publicKey: "", wgPort: 51820, loadScore: 0.5, ipv6Available: true, geodnsWeight: 100),
                VPNServer(nodeId: "ewr1", site: "ewr1", region: "us", displayName: "Newark", ipv4: "64.176.215.96", ipv6: "fd10:0:13::1", endpoints: .init(primary: "ewr1.example.com", secondary: "64.176.215.96"), publicKey: "", wgPort: 51820, loadScore: 0.5, ipv6Available: true, geodnsWeight: 100),
                VPNServer(nodeId: "sgp2", site: "sgp2", region: "sg", displayName: "Singapore", ipv4: "149.28.132.184", ipv6: "fd10:0:8::1", endpoints: .init(primary: "sgp2.example.com", secondary: "149.28.132.184"), publicKey: "", wgPort: 51820, loadScore: 0.5, ipv6Available: true, geodnsWeight: 100),
                VPNServer(nodeId: "nrt1", site: "nrt1", region: "jp", displayName: "Tokyo", ipv4: "167.179.82.216", ipv6: "fd10:0:10::1", endpoints: .init(primary: "nrt1.example.com", secondary: "167.179.82.216"), publicKey: "", wgPort: 51820, loadScore: 0.5, ipv6Available: true, geodnsWeight: 100),
                VPNServer(nodeId: "bom1", site: "bom1", region: "in", displayName: "Mumbai", ipv4: "65.20.76.56", ipv6: "fd10:0:12::1", endpoints: .init(primary: "bom1.example.com", secondary: "65.20.76.56"), publicKey: "", wgPort: 51820, loadScore: 0.5, ipv6Available: true, geodnsWeight: 100),
                VPNServer(nodeId: "hil2", site: "hil2", region: "us", displayName: "Hillsboro-2", ipv4: "5.78.207.199", ipv6: "fd10:0:3::1", endpoints: .init(primary: "hil2.example.com", secondary: "5.78.207.199"), publicKey: "", wgPort: 51820, loadScore: 0.5, ipv6Available: true, geodnsWeight: 100),
            ]
            servers = mockRegions.map { ServerLatency(server: $0, milliseconds: Double.random(in: 30...180)) }
            selectedServer = mockRegions.first
            isLoading = false
            return
        }

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

    func selectServer(_ server: VPNServer) {
        selectedServer = server
    }

    // MARK: - Latency probing

    private func probeAll(_ rawServers: [VPNServer]) async {
        await withTaskGroup(of: (String, Double?).self) { group in
            for server in rawServers {
                group.addTask { [weak self] in
                    guard let self else { return (server.nodeId, nil) }
                    // Try primary endpoint (may be IPv6). If it fails (e.g. IPv4-only
                    // device or IPv6 extraction error), fall back to secondary (IPv4).
                    var ms = await self.probe(host: server.endpoints.primary)
                    if ms == nil, let secondary = server.endpoints.secondary {
                        ms = await self.probe(host: secondary)
                    }
                    return (server.nodeId, ms)
                }
            }

            var results: [String: Double?] = [:]
            for await (nodeId, ms) in group {
                results[nodeId] = ms
                // Update progressively so each ping appears as it lands
                let partial = rawServers.map { srv in
                    ServerLatency(server: srv, milliseconds: results[srv.nodeId] ?? nil)
                }
                servers = partial.sorted {
                    switch ($0.milliseconds, $1.milliseconds) {
                    case (let a?, let b?): return a < b
                    case (.some, nil):     return true
                    case (nil, .some):     return false
                    case (nil, nil):       return false
                    }
                }
            }

            // Auto-select: if selectedServer is already set (e.g. synced from the
            // connected node), leave it alone. Otherwise pick the fastest measured node.
            if selectedServer == nil, let fastest = servers.first(where: { $0.milliseconds != nil }) {
                selectedServer = fastest.server
            }
        }
    }

    /// TCP connect to host:probePort, returns round-trip in milliseconds or nil on failure.
    private func probe(host: String) async -> Double? {
        // Extract hostname, stripping any port suffix.
        // Handles three formats:
        //   [ipv6address]:port  →  ipv6address   (bracket-quoted IPv6)
        //   ipv4:port           →  ipv4
        //   hostname            →  hostname       (no port)
        var hostname = host
        if host.hasPrefix("[") {
            // IPv6 with port: [address]:port — extract address between brackets
            if let close = host.firstIndex(of: "]") {
                hostname = String(host[host.index(after: host.startIndex)..<close])
            }
        } else if host.contains(":") {
            hostname = String(host.split(separator: ":", maxSplits: 1)[0])
        }

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(hostname),
            port: probePort
        )
        let params = NWParameters.tcp
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
