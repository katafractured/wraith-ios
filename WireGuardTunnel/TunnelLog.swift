// TunnelLog.swift
// WireGuardTunnel
//
// Tiny logging wrapper used by the NEPacketTunnelProvider. Forwards every
// message to `os_log` (preserving the existing unified-log subsystem so
// macOS Console / `log show --predicate` still works) AND mirrors the
// entry to `SharedDebugLogStore` so the main app's Diagnostics screen
// can show the line on-device — Tek can grab Stealth-attempt logs from
// his iPhone without USB + Console.app.
//
// Privacy:
//   - The os_log call uses .public formatting (matches existing behavior).
//   - The shared-store mirror NEVER receives raw tokens, IPs, or peer
//     pubkeys. Callers must redact via `Redact.tail4 / .ends / .hash8`
//     before passing the message in.

import Foundation
import os.log

/// File-scoped os.log Logger — keeps the existing
/// `com.katafract.wraith.tunnel` / `PacketTunnelProvider` subsystem so
/// the unified-log developer flow continues to work unchanged.
private let osLogger = Logger(
    subsystem: "com.katafract.wraith.tunnel",
    category: "PacketTunnelProvider"
)

enum TunnelLogLevel: String {
    case debug   = "debug"
    case info    = "info"
    case warning = "warning"
    case error   = "error"
}

/// Logging facade for the tunnel extension. Use this instead of `os_log`
/// directly so every message also lands in the shared in-app log buffer.
enum TunnelLog {

    // MARK: - Generic entry point

    /// Append a tagged entry. `subsystem` is the in-app filter tag (e.g.
    /// "Stealth", "WG", "NE") — independent of the os.log subsystem.
    static func log(_ level: TunnelLogLevel,
                    subsystem: String,
                    _ message: String) {
        // 1. Mirror to the shared on-device buffer. PII is the caller's
        //    responsibility — we just write the string.
        let entry = SharedDebugLogEntry(
            subsystem: subsystem,
            level: level.rawValue,
            message: message
        )
        SharedDebugLogStore.shared.append(entry)

        // 2. Forward to os.log with .public privacy so Console.app /
        //    `log show` still print readable text.
        switch level {
        case .debug:
            osLogger.debug("[\(subsystem, privacy: .public)] \(message, privacy: .public)")
        case .info:
            osLogger.info("[\(subsystem, privacy: .public)] \(message, privacy: .public)")
        case .warning:
            osLogger.warning("[\(subsystem, privacy: .public)] \(message, privacy: .public)")
        case .error:
            osLogger.error("[\(subsystem, privacy: .public)] \(message, privacy: .public)")
        }
    }

    // MARK: - Convenience by subsystem

    /// "NE" — generic NetworkExtension lifecycle (startTunnel/stopTunnel).
    static func ne(_ level: TunnelLogLevel, _ message: String) {
        log(level, subsystem: "NE", message)
    }

    /// "WG" — WireGuard adapter / config events.
    static func wg(_ level: TunnelLogLevel, _ message: String) {
        log(level, subsystem: "WG", message)
    }

    /// "Stealth" — Shadowsocks fallback path. Tek's primary debugging filter.
    static func stealth(_ level: TunnelLogLevel, _ message: String) {
        log(level, subsystem: "Stealth", message)
    }
}
