// LatencyProbe.swift
// WraithVPN
//
// Phase E2.2 — client-measured RTT to each healthy region.
//
// Groups the fetched server list by region, picks one representative node per
// region, and runs TCP-connect probes to port 22 (same port ServerListManager
// uses — 443 is DROP on these nodes, 22 is open and returns real .ready RTT).
// Median of N samples per region, then APIClient.reportLatency posts to the
// server. 24h TTL on the server side; selector does not yet read the data.

import Foundation
import Network

enum LatencyProbeNetClass: String {
    case wifi
    case cellular
    case wired
    case unknown
}

enum LatencyProbe {

    private static let probePort: NWEndpoint.Port = 22
    private static let probeTimeout: TimeInterval = 3.0
    private static let samplesPerRegion: Int = 3

    /// Probe each region via one representative node. Returns `region_id → median_ms`.
    /// Only includes regions where at least 1 sample succeeded.
    static func probeRegions(from servers: [VPNServer]) async -> [String: Int] {
        let representatives = pickRepresentatives(servers)
        var out: [String: Int] = [:]

        await withTaskGroup(of: (String, Int?).self) { group in
            for (regionId, server) in representatives {
                group.addTask {
                    let host = preferredHost(for: server)
                    var samples: [Double] = []
                    for _ in 0 ..< samplesPerRegion {
                        if let ms = await probe(host: host) {
                            samples.append(ms)
                        }
                    }
                    guard !samples.isEmpty else { return (regionId, nil) }
                    let sorted = samples.sorted()
                    let median = sorted[sorted.count / 2]
                    return (regionId, Int(median.rounded()))
                }
            }
            for await (regionId, ms) in group {
                if let ms { out[regionId] = ms }
            }
        }
        return out
    }

    /// One representative server per region. Deterministic: lowest nodeId.
    private static func pickRepresentatives(_ servers: [VPNServer]) -> [String: VPNServer] {
        var byRegion: [String: [VPNServer]] = [:]
        for s in servers where !s.region.isEmpty {
            byRegion[s.region, default: []].append(s)
        }
        var reps: [String: VPNServer] = [:]
        for (region, nodes) in byRegion {
            if let pick = nodes.sorted(by: { $0.nodeId < $1.nodeId }).first {
                reps[region] = pick
            }
        }
        return reps
    }

    /// Strip any port suffix or IPv6 brackets; prefer primary endpoint.
    private static func preferredHost(for server: VPNServer) -> String {
        let raw = server.endpoints.primary.isEmpty
            ? (server.endpoints.secondary ?? server.ipv4)
            : server.endpoints.primary
        if raw.hasPrefix("["), let close = raw.firstIndex(of: "]") {
            return String(raw[raw.index(after: raw.startIndex) ..< close])
        }
        if raw.contains(":") {
            return String(raw.split(separator: ":", maxSplits: 1)[0])
        }
        return raw
    }

    /// TCP connect to host:22 — same mechanism as ServerListManager. Returns
    /// round-trip milliseconds, or nil on timeout/failure. Bypasses any active
    /// tunnel interface so the sample measures the user's real underlay.
    private static func probe(host: String) async -> Double? {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: probePort
        )
        let params = NWParameters.tcp
        params.prohibitedInterfaceTypes = [.other]
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
                if result == nil { connection.cancel() }
                continuation.resume(returning: result)
            }

            timeout = DispatchWorkItem { finish(with: nil) }
            DispatchQueue.global().asyncAfter(deadline: .now() + probeTimeout, execute: timeout!)

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let ms = Date().timeIntervalSince(start) * 1000
                    connection.cancel()
                    finish(with: ms)
                case .failed(let error):
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
