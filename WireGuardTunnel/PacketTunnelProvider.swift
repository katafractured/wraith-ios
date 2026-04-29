// PacketTunnelProvider.swift
// WireGuardTunnel
//
// NetworkExtension packet tunnel provider that boots the WireGuard backend
// using a wg-quick style configuration string supplied by the main app.

import NetworkExtension
import WireGuardKit
import os.log
import Foundation

// File-scoped os.log Logger kept around for the WireGuardKit adapter
// callback (which expects an `OSLogType`-style sink). Everything else
// in this file goes through `TunnelLog` so the in-app Diagnostics
// screen sees the same lines on-device.
private let log = Logger(subsystem: "com.katafract.wraith.tunnel", category: "PacketTunnelProvider")
private let appGroupDefaults = UserDefaults(suiteName: "group.com.katafract.wraith")

private func writeTunnelError(_ message: String) {
    let entry = "\(ISO8601DateFormatter().string(from: Date())) \(message)"
    appGroupDefaults?.set(entry, forKey: "lastTunnelError")
    // Mirror to TunnelLog so the in-app Diagnostics screen captures the line.
    TunnelLog.ne(.error, message)
}

final class PacketTunnelProvider: NEPacketTunnelProvider {

    private lazy var adapter: WireGuardAdapter = {
        WireGuardAdapter(with: self) { logLevel, message in
            // WireGuard kernel-level log lines stay raw on os.log only —
            // they're high-frequency and would dominate the in-app buffer.
            log.log(level: logLevel.osLogType, "\(message, privacy: .public)")
        }
    }()

    /// Active Shadowsocks transport (non-nil when SS fallback is running).
    private var shadowsocksTransport: ShadowsocksTransport?

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        TunnelLog.ne(.info, "startTunnel called")

        guard let proto = protocolConfiguration as? NETunnelProviderProtocol,
              let providerConfig = proto.providerConfiguration,
              let wgConfig = providerConfig["wgConfig"] as? String else {
            writeTunnelError("startTunnel: missing wgConfig in providerConfiguration")
            completionHandler(TunnelError.missingConfiguration)
            return
        }

        let tunnelConfiguration: TunnelConfiguration
        do {
            tunnelConfiguration = try TunnelConfiguration.makeWraithConfiguration(from: wgConfig, name: "wraith")
        } catch {
            writeTunnelError("startTunnel: config parse failed — \(error.localizedDescription)")
            completionHandler(TunnelError.invalidConfiguration)
            return
        }

        adapter.start(tunnelConfiguration: tunnelConfiguration) { [weak self] adapterError in
            guard let self else {
                writeTunnelError("startTunnel: adapter deallocated before start completed")
                completionHandler(TunnelError.adapterDeallocated)
                return
            }

            guard let adapterError else {
                let interfaceName = self.adapter.interfaceName ?? "unknown"
                appGroupDefaults?.removeObject(forKey: "lastTunnelError")
                TunnelLog.wg(.info, "WireGuard tunnel started on interface \(interfaceName)")
                completionHandler(nil)
                return
            }

            writeTunnelError("startTunnel: adapter failed — \(adapterError.asTunnelError.localizedDescription)")
            completionHandler(adapterError.asTunnelError)
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        TunnelLog.ne(.info, "stopTunnel called, reason=\(reason.rawValue)")

        adapter.stop { adapterError in
            if let adapterError {
                TunnelLog.wg(.error, "Failed to stop WireGuard adapter: \(String(describing: adapterError))")
            }
            completionHandler()
        }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let completionHandler else { return }

        if messageData.count == 1, messageData[0] == 0x00 {
            // Message 0x00: get runtime WireGuard config string
            adapter.getRuntimeConfiguration { config in
                completionHandler(config?.data(using: .utf8))
            }

        } else if messageData.count == 1, messageData[0] == 0x01 {
            // Message 0x01: switch to Shadowsocks fallback transport
            Task {
                let success = await self.startShadowsocksFallback()
                completionHandler(Data([success ? 0x01 : 0x00]))
            }

        } else if messageData.count == 1, messageData[0] == 0x02 {
            // Message 0x02: restart WireGuard adapter (after failed SS attempt)
            Task {
                let success = await self.restartWireGuardAdapter()
                completionHandler(Data([success ? 0x01 : 0x00]))
            }

        } else {
            completionHandler(nil)
        }
    }

    /// Reads activeShadowsocksConfig from App Group UserDefaults and starts
    /// ShadowsocksTransport. Stops WireGuard adapter first to avoid UDP/TCP conflict.
    ///
    /// Bug fix (2026-04-29): previously this returned success the moment
    /// `transport.start()` returned — but `transport.start()` only sends the
    /// SS-2022 wire prefix (salt+EIH+enc(header)+enc(addrData)) and does NOT
    /// verify that the server actually authenticated and accepted it. If PSK
    /// is wrong, server certificate fails, or the v2ray-plugin WS layer
    /// rejects, the failure shows up only later in the read/write loops —
    /// well after the IPC reply has already gone back as 0x01. The main app
    /// then flips `activeTransport=.shadowsocks` even though zero SS bytes
    /// reach the server. This was the TestFlight 1456 ghost-Stealth bug.
    ///
    /// New flow:
    ///   1. Await `adapter.stop` to completion (was fire-and-forget).
    ///   2. Tear down tunnel network settings to nil so any NWConnection we
    ///      open inside the extension uses the underlying physical interface
    ///      instead of a defunct utun.
    ///   3. Re-apply tunnel network settings (route 0/0, DNS) so packetFlow
    ///      remains valid for the SS read/write loops.
    ///   4. Start ShadowsocksTransport.
    ///   5. Call `transport.verify()` — sends a real WG handshake-init packet
    ///      through the SS tunnel and waits for the server to echo a response
    ///      within 3s. Only then return 0x01 to the main app.
    private func startShadowsocksFallback() async -> Bool {
        let blobLen = appGroupDefaults?.data(forKey: "activeShadowsocksConfig")?.count ?? 0
        TunnelLog.stealth(.info, "extension: startShadowsocksFallback ENTRY, configBlobLen=\(blobLen)")

        guard let configData = appGroupDefaults?.data(forKey: "activeShadowsocksConfig"),
              let ssConfig = try? JSONDecoder().decode(ShadowsocksConfig.self, from: configData) else {
            TunnelLog.stealth(.error, "extension: activeShadowsocksConfig missing or decode failed (blobLen=\(blobLen))")
            return false
        }
        TunnelLog.stealth(.info, "extension: SS config parsed OK — server=\(Redact.ends(ssConfig.server)) port=\(ssConfig.port)")

        // Derive WG server public IP from the loaded config's server field — this is the
        // node public IP (e.g., 87.99.128.159) that WireGuard also connects to.
        // For SS-2022, serverNodeIP is the WG peer endpoint IP (passed as SOCKS5 target).
        // We store it in the SS config's pluginOpts field as "tls;host=<hostname>".
        // The actual WG destination IP is the assigned peer's endpoint — stored separately.
        // Use the server hostname's resolved IP (or fall back to an App Group stored value).
        let serverNodeIP = appGroupDefaults?.string(forKey: "wgExitIP") ?? ssConfig.server

        let tunnelConfig = SSTunnelConfig(
            server: ssConfig.server,
            port: UInt16(clamping: ssConfig.port),
            password: ssConfig.password,
            serverNodeIP: serverNodeIP
        )
        TunnelLog.stealth(.info, "Config: server=\(Redact.ends(ssConfig.server)) port=\(ssConfig.port) targetWG=\(Redact.ends(serverNodeIP))")

        // 1. Await WG adapter stop to completion before opening new sockets.
        TunnelLog.stealth(.info, "Stopping WireGuard adapter (awaiting completion)…")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            adapter.stop { error in
                if let error {
                    TunnelLog.stealth(.error, "adapter.stop error: \(error)")
                } else {
                    TunnelLog.stealth(.info, "adapter.stop completed")
                }
                continuation.resume()
            }
        }

        // 2. Drop tunnel network settings to nil so the extension's outbound
        // NWConnection is forced onto the physical interface (Wi-Fi/cellular)
        // instead of trying to route via the now-defunct utun.
        TunnelLog.stealth(.info, "Clearing tunnel network settings (so SS NWConnection bypasses utun)…")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.setTunnelNetworkSettings(nil) { error in
                if let error {
                    TunnelLog.stealth(.error, "setTunnelNetworkSettings(nil) error: \(error.localizedDescription)")
                } else {
                    TunnelLog.stealth(.info, "setTunnelNetworkSettings(nil) ok")
                }
                continuation.resume()
            }
        }

        // 3. Start SS transport (TLS connect + WS handshake + send wire prefix).
        TunnelLog.stealth(.info, "Starting ShadowsocksTransport…")
        let transport = ShadowsocksTransport()
        do {
            try await transport.start(config: tunnelConfig, packetFlow: packetFlow)
        } catch {
            TunnelLog.stealth(.error, "transport.start FAILED: \(error.localizedDescription)")
            return false
        }
        TunnelLog.stealth(.info, "transport.start ok (TLS+WS+SS prefix sent)")

        // 4. Verify server actually accepted the SS auth — without this check
        // we'd return success even when the server silently rejected the PSK.
        TunnelLog.stealth(.info, "Verifying SS connection (polling state for 3s)…")
        let verified = await transport.verifyServerAccepted(timeoutSeconds: 3)
        guard verified else {
            TunnelLog.stealth(.error, "VERIFY FAILED: connection state went unhealthy within 3s — SS rejected by server (PSK / cert / WS / DPI). Tearing down.")
            await transport.stop()
            return false
        }
        TunnelLog.stealth(.info, "Connection healthy — SS auth accepted")

        // 5. Re-apply tunnel network settings so packetFlow keeps producing
        // packets from the OS routing table. We re-use the WG-era settings
        // (route 0/0, DNS) — only the underlying transport is different.
        if let proto = self.protocolConfiguration as? NETunnelProviderProtocol,
           let providerConfig = proto.providerConfiguration,
           let wgConfig = providerConfig["wgConfig"] as? String {
            await applyTunnelSettings(forWGConfig: wgConfig, tag: "SS-mode")
        } else {
            TunnelLog.stealth(.warning, "cannot re-apply tunnel settings — providerConfiguration missing. packetFlow may stop yielding.")
        }

        // 6. Spawn read/write loops only AFTER verify succeeded.
        await transport.startPumps(packetFlow: packetFlow)

        self.shadowsocksTransport = transport
        TunnelLog.stealth(.info, "SS fallback engaged (transport active, pumps running)")
        return true
    }

    /// Re-applies network settings derived from a WG config (used after
    /// switching transports). Pulls Address + DNS from the WG INI text and
    /// installs a 0/0 default route. Best-effort: failures are logged but
    /// not fatal because packetFlow still works without re-applied settings
    /// in the simple case where the OS hasn't torn them down yet.
    private func applyTunnelSettings(forWGConfig wgConfig: String, tag: String) async {
        // Parse the few fields we need out of the wg-quick INI.
        var address: String?
        var dnsServers: [String] = []
        for rawLine in wgConfig.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let val = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if key == "address" {
                address = val.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.first
            } else if key == "dns" {
                dnsServers.append(contentsOf: val.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            }
        }

        let v4: String
        if let a = address?.split(separator: "/").first.map(String.init) { v4 = a } else { v4 = "10.0.0.2" }

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: v4)
        let v4Settings = NEIPv4Settings(addresses: [v4], subnetMasks: ["255.255.255.255"])
        v4Settings.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = v4Settings
        if !dnsServers.isEmpty {
            settings.dnsSettings = NEDNSSettings(servers: dnsServers)
        }
        settings.mtu = 1420

        TunnelLog.stealth(.info, "Applying tunnel network settings (\(tag)) — addr=\(v4) dns=\(dnsServers.joined(separator: ","))")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.setTunnelNetworkSettings(settings) { error in
                if let error {
                    TunnelLog.stealth(.error, "setTunnelNetworkSettings(\(tag)) error: \(error.localizedDescription)")
                } else {
                    TunnelLog.stealth(.info, "setTunnelNetworkSettings(\(tag)) applied")
                }
                continuation.resume()
            }
        }
    }

    /// Restarts the WireGuard adapter after a failed Shadowsocks fallback attempt.
    /// Called via IPC message 0x02 from the main app when SS engagement fails.
    /// This ensures the user retains connectivity via direct WireGuard.
    private func restartWireGuardAdapter() async -> Bool {
        TunnelLog.stealth(.info, "extension: restartWireGuardAdapter (SS fallback failed)")
        // Stop any active Shadowsocks transport first
        if let transport = shadowsocksTransport {
            await transport.stop()
            shadowsocksTransport = nil
        }
        // Restart WireGuard using the same configuration as startTunnel
        guard let proto = protocolConfiguration as? NETunnelProviderProtocol,
              let providerConfig = proto.providerConfiguration,
              let wgConfig = providerConfig["wgConfig"] as? String else {
            TunnelLog.wg(.error, "restartWireGuardAdapter: missing wgConfig")
            return false
        }
        let tunnelConfiguration: TunnelConfiguration
        do {
            tunnelConfiguration = try TunnelConfiguration.makeWraithConfiguration(from: wgConfig, name: "wraith")
        } catch {
            TunnelLog.wg(.error, "restartWireGuardAdapter: config parse failed — \(error.localizedDescription)")
            return false
        }
        return await withCheckedContinuation { continuation in
            adapter.start(tunnelConfiguration: tunnelConfiguration) { adapterError in
                if let adapterError {
                    TunnelLog.wg(.error, "restartWireGuardAdapter: start failed — \(adapterError)")
                    continuation.resume(returning: false)
                } else {
                    TunnelLog.wg(.info, "WireGuard adapter restarted successfully")
                    continuation.resume(returning: true)
                }
            }
        }
    }
}

private extension TunnelConfiguration {
    static func makeWraithConfiguration(from wgQuickConfig: String, name: String) throws -> TunnelConfiguration {
        enum Section {
            case none
            case interface
            case peer
        }

        var interfaceConfiguration: InterfaceConfiguration?
        var peerConfigurations = [PeerConfiguration]()
        var section = Section.none
        var attributes = [String: String]()

        func commitCurrentSection() throws {
            switch section {
            case .none:
                return
            case .interface:
                guard interfaceConfiguration == nil else {
                    throw TunnelError.invalidConfiguration
                }
                interfaceConfiguration = try makeInterfaceConfiguration(from: attributes)
            case .peer:
                peerConfigurations.append(try makePeerConfiguration(from: attributes))
            }
        }

        for rawLine in wgQuickConfig.split(whereSeparator: \.isNewline) {
            let uncommentedLine = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let line = uncommentedLine.trimmingCharacters(in: .whitespacesAndNewlines)

            if line.isEmpty {
                continue
            }

            let normalizedLine = line.lowercased()
            if normalizedLine == "[interface]" || normalizedLine == "[peer]" {
                try commitCurrentSection()
                attributes.removeAll()
                section = normalizedLine == "[interface]" ? .interface : .peer
                continue
            }

            guard let equalsIndex = line.firstIndex(of: "=") else {
                throw TunnelError.invalidConfiguration
            }

            let key = line[..<equalsIndex].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: equalsIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)

            if let existingValue = attributes[key], ["address", "allowedips", "dns"].contains(key) {
                attributes[key] = existingValue + "," + value
            } else if attributes[key] == nil {
                attributes[key] = value
            } else {
                throw TunnelError.invalidConfiguration
            }
        }

        try commitCurrentSection()

        guard let interfaceConfiguration else {
            throw TunnelError.invalidConfiguration
        }

        return TunnelConfiguration(name: name, interface: interfaceConfiguration, peers: peerConfigurations)
    }

    static func makeInterfaceConfiguration(from attributes: [String: String]) throws -> InterfaceConfiguration {
        guard let privateKeyString = attributes["privatekey"],
              let privateKey = PrivateKey(base64Key: privateKeyString) else {
            throw TunnelError.invalidConfiguration
        }

        var interface = InterfaceConfiguration(privateKey: privateKey)

        if let listenPortString = attributes["listenport"] {
            guard let listenPort = UInt16(listenPortString) else {
                throw TunnelError.invalidConfiguration
            }
            interface.listenPort = listenPort
        }

        if let addressesString = attributes["address"] {
            interface.addresses = try parseRanges(addressesString)
        }

        if let dnsString = attributes["dns"] {
            var dnsServers = [DNSServer]()
            var dnsSearch = [String]()

            for value in splitCSV(dnsString) {
                if let dnsServer = DNSServer(from: value) {
                    dnsServers.append(dnsServer)
                } else {
                    dnsSearch.append(value)
                }
            }

            interface.dns = dnsServers
            interface.dnsSearch = dnsSearch
        }

        if let mtuString = attributes["mtu"] {
            guard let mtu = UInt16(mtuString) else {
                throw TunnelError.invalidConfiguration
            }
            interface.mtu = mtu
        }

        // AmneziaWG obfuscation parameters
        if let v = attributes["jc"].flatMap(UInt16.init)  { interface.junkPacketCount = v }
        if let v = attributes["jmin"].flatMap(UInt16.init) { interface.junkPacketMinSize = v }
        if let v = attributes["jmax"].flatMap(UInt16.init) { interface.junkPacketMaxSize = v }
        if let v = attributes["s1"].flatMap(UInt16.init)   { interface.initPacketJunkSize = v }
        if let v = attributes["s2"].flatMap(UInt16.init)   { interface.responsePacketJunkSize = v }
        if let v = attributes["h1"] { interface.initPacketMagicHeader = v }
        if let v = attributes["h2"] { interface.responsePacketMagicHeader = v }
        if let v = attributes["h3"] { interface.underloadPacketMagicHeader = v }
        if let v = attributes["h4"] { interface.transportPacketMagicHeader = v }

        return interface
    }

    static func makePeerConfiguration(from attributes: [String: String]) throws -> PeerConfiguration {
        guard let publicKeyString = attributes["publickey"],
              let publicKey = PublicKey(base64Key: publicKeyString) else {
            throw TunnelError.invalidConfiguration
        }

        var peer = PeerConfiguration(publicKey: publicKey)

        if let preSharedKeyString = attributes["presharedkey"] {
            guard let preSharedKey = PreSharedKey(base64Key: preSharedKeyString) else {
                throw TunnelError.invalidConfiguration
            }
            peer.preSharedKey = preSharedKey
        }

        if let allowedIPsString = attributes["allowedips"] {
            peer.allowedIPs = try parseRanges(allowedIPsString)
        }

        if let endpointString = attributes["endpoint"] {
            guard let endpoint = Endpoint(from: endpointString) else {
                throw TunnelError.invalidConfiguration
            }
            peer.endpoint = endpoint
        }

        if let keepAliveString = attributes["persistentkeepalive"] {
            guard let keepAlive = UInt16(keepAliveString) else {
                throw TunnelError.invalidConfiguration
            }
            peer.persistentKeepAlive = keepAlive
        }

        return peer
    }

    static func parseRanges(_ value: String) throws -> [IPAddressRange] {
        try splitCSV(value).map { item in
            guard let range = IPAddressRange(from: item) else {
                throw TunnelError.invalidConfiguration
            }
            return range
        }
    }

    static func splitCSV(_ value: String) -> [String] {
        value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

enum TunnelError: LocalizedError {
    case missingConfiguration
    case invalidConfiguration
    case dnsResolutionFailure
    case couldNotSetNetworkSettings
    case couldNotStartBackend
    case couldNotDetermineFileDescriptor
    case adapterDeallocated

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return "WireGuard configuration missing from provider configuration dictionary."
        case .invalidConfiguration:
            return "The saved WireGuard configuration could not be parsed."
        case .dnsResolutionFailure:
            return "DNS resolution failed for the WireGuard endpoint."
        case .couldNotSetNetworkSettings:
            return "The tunnel network settings could not be applied."
        case .couldNotStartBackend:
            return "The WireGuard backend failed to start."
        case .couldNotDetermineFileDescriptor:
            return "WireGuard could not determine the tunnel file descriptor."
        case .adapterDeallocated:
            return "The WireGuard adapter was released before startup completed."
        }
    }
}

private extension WireGuardAdapterError {
    var asTunnelError: TunnelError {
        switch self {
        case .cannotLocateTunnelFileDescriptor:
            return .couldNotDetermineFileDescriptor
        case .dnsResolution:
            return .dnsResolutionFailure
        case .setNetworkSettings:
            return .couldNotSetNetworkSettings
        case .startWireGuardBackend:
            return .couldNotStartBackend
        case .invalidState:
            return .invalidConfiguration
        }
    }
}

private extension WireGuardLogLevel {
    var osLogType: OSLogType {
        switch self {
        case .verbose:
            return .debug
        case .error:
            return .error
        }
    }
}
