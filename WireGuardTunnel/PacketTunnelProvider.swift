// PacketTunnelProvider.swift
// WireGuardTunnel
//
// NetworkExtension packet tunnel provider that boots the WireGuard backend
// using a wg-quick style configuration string supplied by the main app.

import NetworkExtension
import WireGuardKit
import os.log
import Foundation
import Network
import Darwin

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
    /// Bug-fix history:
    ///   • PR #51 (2026-04-29, build 1457): added await adapter.stop +
    ///     setTunnelNetworkSettings(nil) + verifyServerAccepted before
    ///     returning success — closed the "transport.start optimistic OK"
    ///     hole. But TestFlight build 1457 still showed ZERO packets ever
    ///     reaching the server (server-side tcpdump :8443 = empty), proving
    ///     the kernel was silently dropping our bytes.
    ///   • THIS PR (2026-04-28): fix the kernel-drop. Three real bugs:
    ///       Bug 1 — NWConnection wasn't pinned to a physical WAN interface.
    ///         After utun teardown the kernel had no obvious route, so
    ///         packets queued against the dead utun and were never sent.
    ///         Fix: snapshot WAN type via NWPathMonitor BEFORE adapter.stop,
    ///         then construct NWParameters with requiredInterfaceType set.
    ///       Bug 2 — Hostname resolution went through the dead utun's DNS,
    ///         sometimes caching NXDOMAIN. Fix: getaddrinfo BEFORE clearing
    ///         tunnel settings; pass IP literal to ShadowsocksTransport;
    ///         set TLS SNI explicitly so the cert still matches.
    ///       Bug 3 — verifyServerAccepted only polled connection.state, which
    ///         only proves local TLS handshake succeeded — NOT that bytes
    ///         left the device. Fix: race a real receive() against a hard
    ///         timeout and log NWConnection.currentPath.availableInterfaces
    ///         so server-silence vs interface-misroute is distinguishable.
    ///
    /// New flow:
    ///   0a. Snapshot WAN interface type (Bug 1 pre-flight).
    ///   0b. Resolve SS hostname → IP (Bug 2 pre-flight).
    ///   1.  Await `adapter.stop` to completion.
    ///   2.  Tear down tunnel network settings to nil so the extension's
    ///       NWConnection routes through the physical interface it pinned
    ///       at step 0a.
    ///   3.  Start ShadowsocksTransport with pre-resolved IP + pinned iface.
    ///   4.  Call verifyServerAccepted (now a real-bytes probe).
    ///   5.  Re-apply tunnel network settings so packetFlow keeps producing.
    ///   6.  Spawn read/write pumps.
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

        // ----- Pre-flight (Bug 1+2 fix, 2026-04-28) -----
        // We must capture two pieces of WAN state BEFORE we tear down the WG
        // adapter, otherwise:
        //   • NWPathMonitor sees only utun and reports `.other` (Bug 1)
        //   • System resolver tries (and fails) to query DNS through the dead
        //     utun, sometimes caching NXDOMAIN (Bug 2)
        //
        // Both of those failures are silent — the kernel just drops packets,
        // server-side tcpdump shows nothing, and the iOS log claims success.
        // That was the TestFlight build 1457 ghost-Stealth bug.

        // 1a. Snapshot the underlying physical WAN interface type.
        let wanIface = await snapshotWANInterfaceType()
        TunnelLog.stealth(.info, "Pre-flight: physical WAN interface = \(ShadowsocksTransport.ifaceName(wanIface))")

        // 1b. Resolve SS server hostname to an IP literal while DNS still
        // routes through the live tunnel (or the system DNS, depending on
        // current state). On failure we abort with a specific error rather
        // than silently letting the in-extension resolver fail later.
        let resolvedSSIP: String
        do {
            resolvedSSIP = try resolveHostnameSync(ssConfig.server)
            TunnelLog.stealth(.info, "Pre-flight: resolved SS server \(Redact.ends(ssConfig.server)) → \(Redact.ends(resolvedSSIP))")
        } catch {
            TunnelLog.stealth(.error, "Pre-flight: DNS resolution FAILED for \(Redact.ends(ssConfig.server)) — \(error.localizedDescription). Stealth: hostname unresolvable.")
            return false
        }

        let tunnelConfig = SSTunnelConfig(
            server: ssConfig.server,
            serverResolvedIP: resolvedSSIP,
            port: UInt16(clamping: ssConfig.port),
            password: ssConfig.password,
            serverNodeIP: serverNodeIP,
            wanInterfaceType: wanIface
        )
        TunnelLog.stealth(.info, "Config: server=\(Redact.ends(ssConfig.server)) port=\(ssConfig.port) targetWG=\(Redact.ends(serverNodeIP)) iface=\(ShadowsocksTransport.ifaceName(wanIface))")

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

    // MARK: - Pre-flight helpers (Bug 1 + Bug 2 fix, 2026-04-28)

    /// Snapshot the underlying physical WAN interface BEFORE WG teardown.
    ///
    /// Inside an NEPacketTunnelProvider, NWPathMonitor sees both the
    /// physical interface (en0/pdp_ip0) AND any active utun. Once we tear
    /// down WG and call setTunnelNetworkSettings(nil), the path summary
    /// degenerates to `.other` and there's no way to recover the physical
    /// type — meaning we can't pin a fresh NWConnection to .wifi vs .cellular.
    ///
    /// Calling this BEFORE adapter.stop() captures the right value while
    /// both interfaces are visible. If neither wifi nor cellular is
    /// detectable (rare — wired iPad on USB-C ethernet, etc.), we return
    /// `.wifi` as the safest default since iOS's "main interface" is
    /// almost always wifi.
    private func snapshotWANInterfaceType() async -> NWInterface.InterfaceType {
        await withCheckedContinuation { (cont: CheckedContinuation<NWInterface.InterfaceType, Never>) in
            let monitor = NWPathMonitor()
            let lock = NSLock()
            nonisolated(unsafe) var resumed = false

            func finish(_ t: NWInterface.InterfaceType) {
                lock.lock(); defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                monitor.cancel()
                cont.resume(returning: t)
            }

            monitor.pathUpdateHandler = { path in
                // Prefer the type of the first available physical interface.
                // Skip .other (utun) and .loopback. Order: wifi, cellular, wired.
                if path.usesInterfaceType(.wifi) { finish(.wifi); return }
                if path.usesInterfaceType(.cellular) { finish(.cellular); return }
                if path.usesInterfaceType(.wiredEthernet) { finish(.wiredEthernet); return }
                // Fall back: scan availableInterfaces explicitly.
                for iface in path.availableInterfaces {
                    if iface.type == .wifi { finish(.wifi); return }
                    if iface.type == .cellular { finish(.cellular); return }
                    if iface.type == .wiredEthernet { finish(.wiredEthernet); return }
                }
                // No physical iface visible (very rare). Default to wifi.
                finish(.wifi)
            }
            monitor.start(queue: .global(qos: .userInitiated))

            // Hard 1.5s deadline — pathUpdateHandler usually fires within ~50ms.
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
                finish(.wifi)  // safe default
            }
        }
    }

    /// Synchronous getaddrinfo wrapper — mirrors WireGuardKit's DNSResolver
    /// pattern. Run BEFORE setTunnelNetworkSettings(nil). Prefers IPv4 over
    /// IPv6 because v2ray-plugin server LE certs are CN=hostname for the
    /// IPv4 record (and most Vultr/Hetzner nodes are dual-stack with the
    /// IPv4 in DNS as the canonical record).
    ///
    /// Throws `ShadowsocksError.dnsResolutionFailed` on failure.
    private func resolveHostnameSync(_ hostname: String) throws -> String {
        var hints = addrinfo()
        hints.ai_flags = AI_ALL
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var resultPointer: UnsafeMutablePointer<addrinfo>?
        defer { resultPointer.flatMap { freeaddrinfo($0) } }

        let errCode = getaddrinfo(hostname, nil, &hints, &resultPointer)
        guard errCode == 0 else {
            let msg = String(cString: gai_strerror(errCode))
            throw ShadowsocksError.dnsResolutionFailed("getaddrinfo \(hostname): \(msg) (errno=\(errCode))")
        }

        var ipv4: String?
        var ipv6: String?

        var next: UnsafeMutablePointer<addrinfo>? = resultPointer
        while let cur = next?.pointee {
            if cur.ai_family == AF_INET {
                cur.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                    var addr = sin.pointee.sin_addr
                    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    if inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil {
                        if ipv4 == nil { ipv4 = String(cString: buf) }
                    }
                }
            } else if cur.ai_family == AF_INET6 {
                cur.ai_addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { sin6 in
                    var addr = sin6.pointee.sin6_addr
                    var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                    if inet_ntop(AF_INET6, &addr, &buf, socklen_t(INET6_ADDRSTRLEN)) != nil {
                        if ipv6 == nil { ipv6 = String(cString: buf) }
                    }
                }
            }
            next = cur.ai_next
        }

        if let v4 = ipv4 { return v4 }
        if let v6 = ipv6 { return v6 }
        throw ShadowsocksError.dnsResolutionFailed("getaddrinfo \(hostname) returned no A/AAAA")
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
