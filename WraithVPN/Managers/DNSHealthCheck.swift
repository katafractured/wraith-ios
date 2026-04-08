// DNSHealthCheck.swift
// WraithVPN
//
// Post-connect DNS connectivity self-test. Runs automatically after the tunnel
// reports .connected and surfaces results as a banner or debug log entry.
//
// Test 1: resolve google.com via Haven DNS (10.10.x.1) -- the node's AGH
// Test 2: resolve google.com via 1.1.1.1 (Cloudflare fallback)
// Test 3: check WG handshake via NETunnelProviderSession.sendProviderMessage
//
// Diagnosis matrix:
//   T1 pass + T2 pass + T3 pass: tunnel healthy
//   T1 fail + T2 pass + T3 pass: Haven AGH down on this node, fallback works
//   T1 fail + T2 fail + T3 pass: WG connected but DNS misconfigured
//   T1 fail + T2 fail + T3 fail: no WG handshake (peer revoked / server unreachable)

import Foundation
import Network

// MARK: - Result types

enum DNSTestResult {
    case passed(latencyMs: Int)
    case failed(Error?)
    case skipped

    var isPassed: Bool {
        if case .passed = self { return true }
        return false
    }
}

struct TunnelHealthReport {
    let havenDNS: DNSTestResult
    let fallbackDNS: DNSTestResult
    let handshakeOK: Bool
    let timestamp: Date

    var isHealthy: Bool {
        havenDNS.isPassed && handshakeOK
    }

    var diagnosis: String {
        switch (havenDNS.isPassed, fallbackDNS.isPassed, handshakeOK) {
        case (true, true, true):
            return "Tunnel healthy"
        case (true, _, false):
            // DNS works but no handshake -- unusual, maybe timing
            return "DNS resolving but handshake status unknown"
        case (false, true, true):
            return "Haven DNS unreachable on this node. Cloudflare fallback active."
        case (false, true, false):
            return "WG handshake failed. DNS works via fallback only (outside tunnel)."
        case (false, false, true):
            return "WG connected but DNS not routing through tunnel. Check AllowedIPs."
        case (false, false, false):
            return "Tunnel not routing traffic. Peer may be revoked or server unreachable. Re-provisioning recommended."
        case (true, false, _):
            return "Haven DNS works, Cloudflare unreachable -- unexpected. Tunnel partially functional."
        }
    }

    // Reprovision when the WG tunnel is dead AND Haven DNS (inside tunnel) is
    // unreachable. Fallback DNS passing is irrelevant — if there's no handshake
    // and no Haven DNS, the peer is likely revoked or the server unreachable.
    var needsReprovision: Bool {
        !handshakeOK && !havenDNS.isPassed
    }
}

// MARK: - Health checker

final class DNSHealthCheck {

    static let shared = DNSHealthCheck()
    private init() {}

    /// Runs the full health check suite. Timeout per test: 5 seconds.
    func runHealthCheck(havenDNSIP: String?, connection: Any?) async -> TunnelHealthReport {
        let dbg = await DebugLogger.shared

        await dbg.dns("Starting post-connect health check")

        // Test 1: Haven DNS (node's WG interface IP)
        let havenResult: DNSTestResult
        if let havenIP = havenDNSIP, !havenIP.isEmpty {
            await dbg.dns("Test 1: resolving google.com via Haven DNS \(havenIP)")
            havenResult = await resolveDNS(server: havenIP, hostname: "google.com")
        } else {
            await dbg.dns("Test 1: skipped (no Haven DNS IP)")
            havenResult = .skipped
        }

        // Test 2: Haven fallback DNS on fury (outside tunnel — excluded from AllowedIPs)
        let furyHavenDNS = "85.239.240.208"
        await dbg.dns("Test 2: resolving google.com via Haven fallback \(furyHavenDNS)")
        let fallbackResult = await resolveDNS(server: furyHavenDNS, hostname: "google.com")

        // Test 3: WG handshake check via tunnel provider message
        await dbg.dns("Test 3: checking WG handshake status")
        let handshakeOK = await checkHandshake(connection: connection)

        let report = TunnelHealthReport(
            havenDNS: havenResult,
            fallbackDNS: fallbackResult,
            handshakeOK: handshakeOK,
            timestamp: Date()
        )

        await dbg.dns("Health check complete: \(report.diagnosis)")
        if case .passed(let ms) = report.havenDNS {
            await dbg.dns("Haven DNS: OK (\(ms)ms)")
        }
        if case .failed(let err) = report.havenDNS {
            await dbg.dns("Haven DNS: FAILED (\(err?.localizedDescription ?? "timeout"))")
        }
        if case .passed(let ms) = report.fallbackDNS {
            await dbg.dns("Haven fallback DNS: OK (\(ms)ms)")
        }
        if case .failed(let err) = report.fallbackDNS {
            await dbg.dns("Haven fallback DNS: FAILED (\(err?.localizedDescription ?? "timeout"))")
        }
        await dbg.dns("WG handshake: \(handshakeOK ? "OK" : "FAILED")")

        return report
    }

    // MARK: - DNS resolution test

    /// Sends a raw UDP DNS query to the specified server and waits for a response.
    /// This bypasses the system resolver so we test the exact DNS server we want.
    private func resolveDNS(server: String, hostname: String, timeoutSecs: Double = 5.0) async -> DNSTestResult {
        let start = CFAbsoluteTimeGetCurrent()

        return await withCheckedContinuation { continuation in
            let host = NWEndpoint.Host(server)
            let port = NWEndpoint.Port(integerLiteral: 53)
            let params = NWParameters.udp
            let connection = NWConnection(host: host, port: port, using: params)

            var completed = false
            let lock = NSLock()

            func complete(_ result: DNSTestResult) {
                lock.lock()
                guard !completed else { lock.unlock(); return }
                completed = true
                lock.unlock()
                connection.cancel()
                continuation.resume(returning: result)
            }

            // Timeout
            DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSecs) {
                complete(.failed(nil))
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    // Build a minimal DNS A query for the hostname
                    let query = Self.buildDNSQuery(for: hostname)
                    connection.send(content: query, completion: .contentProcessed({ error in
                        if let error {
                            complete(.failed(error))
                            return
                        }
                        // Wait for response
                        connection.receive(minimumIncompleteLength: 1, maximumLength: 512) { data, _, _, error in
                            if let error {
                                complete(.failed(error))
                                return
                            }
                            guard let data, data.count >= 12 else {
                                complete(.failed(nil))
                                return
                            }
                            // Check RCODE in DNS header (bits 12-15 of byte 3)
                            let flags = data[3]
                            let rcode = flags & 0x0F
                            let elapsed = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
                            if rcode == 0 { // NOERROR
                                complete(.passed(latencyMs: elapsed))
                            } else {
                                complete(.failed(nil))
                            }
                        }
                    }))
                case .failed(let error):
                    complete(.failed(error))
                case .cancelled:
                    break
                default:
                    break
                }
            }

            connection.start(queue: .global())
        }
    }

    /// Builds a minimal DNS A query packet for the given hostname.
    private static func buildDNSQuery(for hostname: String) -> Data {
        var data = Data()
        // Transaction ID
        data.append(contentsOf: [0xAB, 0xCD])
        // Flags: standard query, recursion desired
        data.append(contentsOf: [0x01, 0x00])
        // Questions: 1, Answers: 0, Authority: 0, Additional: 0
        data.append(contentsOf: [0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        // QNAME: encode each label
        for label in hostname.split(separator: ".") {
            data.append(UInt8(label.count))
            data.append(contentsOf: label.utf8)
        }
        data.append(0x00) // root label
        // QTYPE: A (1)
        data.append(contentsOf: [0x00, 0x01])
        // QCLASS: IN (1)
        data.append(contentsOf: [0x00, 0x01])
        return data
    }

    // MARK: - WG handshake check

    /// Queries the tunnel extension for runtime config. If the extension responds
    /// with a config that includes a recent last_handshake_time_sec, the tunnel is live.
    private func checkHandshake(connection: Any?) async -> Bool {
        // The tunnel extension responds to a single-byte message (0x00) with
        // the WireGuard runtime configuration as UTF-8 text.
        guard let session = connection as? NETunnelProviderSessionProtocol else {
            return false
        }

        return await withCheckedContinuation { continuation in
            do {
                var completed = false
                let lock = NSLock()

                func complete(_ result: Bool) {
                    lock.lock()
                    guard !completed else { lock.unlock(); return }
                    completed = true
                    lock.unlock()
                    continuation.resume(returning: result)
                }

                // Timeout after 3 seconds
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                    complete(false)
                }

                try session.sendProviderMessage(Data([0])) { response in
                    guard let data = response,
                          let text = String(data: data, encoding: .utf8) else {
                        complete(false)
                        return
                    }
                    // Parse last_handshake_time_sec from the runtime config.
                    // Format: "last_handshake_time_sec=1712345678\n"
                    // A value of 0 means no handshake has occurred.
                    let handshakeOK = text.contains("last_handshake_time_sec=")
                        && !text.contains("last_handshake_time_sec=0\n")
                    complete(handshakeOK)
                }
            } catch {
                continuation.resume(returning: false)
            }
        }
    }
}

// MARK: - Protocol for testability

/// Abstraction over NETunnelProviderSession so we can send provider messages.
/// The real NETunnelProviderSession doesn't conform to any useful protocol,
/// so we define one and extend it.
protocol NETunnelProviderSessionProtocol {
    func sendProviderMessage(_ messageData: Data, responseHandler: ((Data?) -> Void)?) throws
}

import NetworkExtension

extension NETunnelProviderSession: NETunnelProviderSessionProtocol {}
