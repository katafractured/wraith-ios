// PacketTunnelProvider.swift
// WireGuardTunnel (Network Extension target)
//
// This is the out-of-process tunnel provider that actually handles WireGuard
// packet routing. It runs as a separate process with elevated NetworkExtension
// privileges, sandboxed away from the main app.
//
// Integration path:
//   - The main app writes the WireGuard INI config into the shared App Group
//     container before starting the tunnel.
//   - This provider reads the config, hands it to WireGuardKit, and manages
//     the tun interface.
//
// DEPENDENCY: Add WireGuardKit via Swift Package Manager:
//   URL: https://github.com/WireGuard/wireguard-apple
//   Package: WireGuardKit
//
// The tunnel target's bundle ID must be: com.katafract.wraith.tunnel
// and its entitlements must include packet-tunnel-provider + the same
// keychain-access-groups and app-group as the main target.

import NetworkExtension
import os.log

// NOTE: Uncomment after adding WireGuardKit SPM dependency:
// import WireGuardKit

private let log = Logger(subsystem: "com.katafract.wraith.tunnel", category: "PacketTunnelProvider")

class PacketTunnelProvider: NEPacketTunnelProvider {

    // MARK: - WireGuardKit adapter
    // private var adapter: WireGuardAdapter?

    // MARK: - Tunnel lifecycle

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        log.info("startTunnel called")

        guard let proto = protocolConfiguration as? NETunnelProviderProtocol,
              let providerConfig = proto.providerConfiguration,
              let wgConfig = providerConfig["wgConfig"] as? String else {
            let err = TunnelError.missingConfiguration
            log.error("Missing WireGuard config: \(err.localizedDescription)")
            completionHandler(err)
            return
        }

        log.info("WireGuard config received, length=\(wgConfig.count) chars")

        // ---- WireGuardKit integration (uncomment after adding SPM dep) ----
        //
        // let tunnelConfig: TunnelConfiguration
        // do {
        //     tunnelConfig = try TunnelConfiguration(fromWgQuickConfig: wgConfig, called: "wraith")
        // } catch {
        //     completionHandler(error)
        //     return
        // }
        //
        // adapter = WireGuardAdapter(with: self) { logLevel, message in
        //     log.debug("wg[\(logLevel.rawValue)]: \(message)")
        // }
        //
        // adapter?.start(tunnelConfiguration: tunnelConfig) { [weak self] adapterError in
        //     if let error = adapterError {
        //         log.error("WireGuard adapter start failed: \(error.localizedDescription)")
        //         completionHandler(error)
        //         return
        //     }
        //     log.info("WireGuard tunnel started successfully")
        //     completionHandler(nil)
        // }
        // ---- end WireGuardKit block ----

        // Placeholder until WireGuardKit is linked:
        completionHandler(TunnelError.wireGuardKitNotLinked)
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        log.info("stopTunnel called, reason=\(reason.rawValue)")

        // adapter?.stop { completionHandler() }

        // Placeholder:
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        // Can be used to request runtime stats from the tunnel (bytes in/out, handshake time).
        // adapter?.getRuntimeConfiguration { config in
        //     completionHandler?(config?.utf8Data)
        // }
        completionHandler?(nil)
    }
}

// MARK: - Errors

enum TunnelError: LocalizedError {
    case missingConfiguration
    case wireGuardKitNotLinked

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return "WireGuard configuration missing from provider configuration dictionary."
        case .wireGuardKitNotLinked:
            return "WireGuardKit is not yet linked. Add the SPM dependency and uncomment the adapter code."
        }
    }
}
