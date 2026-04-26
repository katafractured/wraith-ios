// PacketTunnelProvider.swift
// WireGuardTunnel
//
// NetworkExtension packet tunnel provider that boots the WireGuard backend
// using a wg-quick style configuration string supplied by the main app.

import NetworkExtension
import WireGuardKit
import os.log
import Foundation

private let log = Logger(subsystem: "com.katafract.wraith.tunnel", category: "PacketTunnelProvider")
private let appGroupDefaults = UserDefaults(suiteName: "group.com.katafract.wraith")

private func writeTunnelError(_ message: String) {
    let entry = "\(ISO8601DateFormatter().string(from: Date())) \(message)"
    appGroupDefaults?.set(entry, forKey: "lastTunnelError")
    log.error("\(message, privacy: .public)")
}

final class PacketTunnelProvider: NEPacketTunnelProvider {

    private lazy var adapter: WireGuardAdapter = {
        WireGuardAdapter(with: self) { logLevel, message in
            log.log(level: logLevel.osLogType, "\(message, privacy: .public)")
        }
    }()

    /// Active Shadowsocks transport (non-nil when SS fallback is running).
    private var shadowsocksTransport: ShadowsocksTransport?

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        log.info("startTunnel called")

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
                log.info("WireGuard tunnel started on interface \(interfaceName, privacy: .public)")
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
        log.info("stopTunnel called, reason=\(reason.rawValue)")

        adapter.stop { adapterError in
            if let adapterError {
                log.error("Failed to stop WireGuard adapter: \(String(describing: adapterError), privacy: .public)")
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

        } else {
            completionHandler(nil)
        }
    }

    /// Reads activeShadowsocksConfig from App Group UserDefaults and starts
    /// ShadowsocksTransport. Stops WireGuard adapter first to avoid UDP/TCP conflict.
    private func startShadowsocksFallback() async -> Bool {
        guard let configData = appGroupDefaults?.data(forKey: "activeShadowsocksConfig"),
              let ssConfig = try? JSONDecoder().decode(ShadowsocksConfig.self, from: configData) else {
            log.error("SS fallback: activeShadowsocksConfig missing or decode failed")
            return false
        }

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

        // Stop the WireGuard adapter (frees the TUN fd so SS can use the packet flow)
        adapter.stop { _ in }
        try? await Task.sleep(nanoseconds: 500_000_000)  // 500ms

        // Start SS transport
        let transport = ShadowsocksTransport()
        do {
            try await transport.start(config: tunnelConfig, packetFlow: packetFlow)
            self.shadowsocksTransport = transport
            log.info("SS fallback: transport started successfully")
            return true
        } catch {
            log.error("SS fallback: transport start failed — \(error.localizedDescription, privacy: .public)")
            return false
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
