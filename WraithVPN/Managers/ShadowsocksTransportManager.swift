// ShadowsocksTransportManager.swift
// WraithVPN
//
// Manages Shadowsocks-over-TLS as a fallback transport when WireGuard handshake
// times out or when stealth mode is explicitly enabled. Uses a simple userspace
// proxy model (no native NEPacketTunnelProvider integration) for MVP.

import Foundation
import Network
import Combine
import os.log

private let log = Logger(subsystem: "com.katafract.wraith", category: "ShadowsocksTransport")

@MainActor
final class ShadowsocksTransportManager: ObservableObject {

    @Published var isConnected: Bool = false
    @Published var lastError: String? = nil
    @Published private(set) var activeConfig: ShadowsocksConfig? = nil

    private var connection: NWConnection?
    private var connectionTask: Task<Void, Never>?

    // MARK: - Public API

    /// Attempt to establish a Shadowsocks connection with the given config.
    /// For MVP, this validates the config and logs readiness; actual proxy
    /// routing via NEPacketTunnelProvider is deferred to Phase 2.
    func connect(with config: ShadowsocksConfig) async {
        log.info("SS: attempting connect to \(config.host):\(config.port, privacy: .public)")

        activeConfig = config
        isConnected = false
        lastError = nil

        // MVP: validate config and signal readiness to tunnel provider
        // Phase 2: implement userspace SOCKS5 proxy or integrate with
        // https://github.com/EbrahimElashry/Shadowsocks-Antinat-iOS
        do {
            try await validateConfig(config)
            isConnected = true
            lastError = nil
        } catch {
            lastError = "Failed to connect: \(error.localizedDescription)"
            isConnected = false
            log.error("SS connect failed: \(String(describing: error), privacy: .public)")
        }
    }

    func disconnect() {
        log.info("SS: disconnecting")
        connection?.cancel()
        connection = nil
        connectionTask?.cancel()
        connectionTask = nil
        isConnected = false
        activeConfig = nil
    }

    // MARK: - Private

    private func validateConfig(_ config: ShadowsocksConfig) async throws {
        // MVP validation: ensure host + port + method + password are non-empty
        guard !config.host.isEmpty,
              config.port > 0 && config.port <= 65535,
              !config.method.isEmpty,
              !config.password.isEmpty else {
            throw NSError(domain: "ShadowsocksTransport", code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "Invalid Shadowsocks config"])
        }

        // In Phase 2, actually attempt a TCP connect to the SS server
        // For now, just validate the parameters.
        log.info("SS config validated: host=\(config.host, privacy: .public), port=\(config.port, privacy: .public), method=\(config.method, privacy: .public)")
    }
}
