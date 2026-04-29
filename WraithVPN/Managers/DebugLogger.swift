// DebugLogger.swift
// WraithVPN
//
// Founder-only trace log system. Captures API calls, WG tunnel state transitions,
// NE error codes, peer/node info, and DNS test results into a ring buffer.
// Viewable in-app and exportable as a "send to support" bundle.
//
// Cross-process: every `log()` call also mirrors to `SharedDebugLogStore` (a
// file-backed buffer in the App Group container) so the WireGuardTunnel
// extension's `TunnelLog` writes show up in the same Diagnostics view.
// Tek can grab Stealth-attempt logs from his iPhone without USB + Console.app.

import Foundation
import Combine
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Log category

enum DebugLogCategory: String {
    case api     = "API"
    case wg      = "WG"
    case ne      = "NE"
    case dns     = "DNS"
    case peer    = "PEER"
    case app     = "APP"
    /// Shadowsocks fallback path. Tek's primary debugging filter.
    case stealth = "Stealth"

    /// Subsystem string used by both `DebugLogger` (in-process) and
    /// `SharedDebugLogStore` (cross-process). Matches what the tunnel
    /// extension writes via `TunnelLog.stealth(...)` so filter chips
    /// merge cleanly across both processes.
    var subsystemTag: String { rawValue }
}

// MARK: - Log entry

struct DebugLogEntry: Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let category: DebugLogCategory
    let message: String
    /// Origin process: "app" (main app) or "ext" (tunnel extension).
    /// Used purely for display — entries from the extension get a small
    /// badge in the row so Tek can tell where the line came from.
    let origin: String

    init(id: UUID = UUID(),
         timestamp: Date = Date(),
         category: DebugLogCategory,
         message: String,
         origin: String = "app") {
        self.id = id
        self.timestamp = timestamp
        self.category = category
        self.message = message
        self.origin = origin
    }

    var formatted: String {
        "[\(debugTimestampFormatter.string(from: timestamp))] [\(category.rawValue)] [\(origin)] \(message)"
    }
}

/// Timestamp formatter used by log entries and the log view.
/// Defined outside the @MainActor class so it's accessible from nonisolated contexts.
let debugTimestampFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
}()

// MARK: - Logger

@MainActor
final class DebugLogger: ObservableObject {

    static let shared = DebugLogger()

    /// Shared App Group UserDefaults — same key store the tunnel reads
    /// to decide whether to mirror its `os_log` lines into the in-app
    /// `SharedDebugLogStore`. Falls back to standard UserDefaults if
    /// the App Group is unavailable (entitlement misconfig).
    private static let sharedDefaults: UserDefaults = {
        UserDefaults(suiteName: DiagnosticsAppGroup.identifier) ?? .standard
    }()

    private static let isEnabledKey = "debugModeEnabled"

    /// Whether debug logging is active. Only toggleable by founder token holders.
    /// Persisted in the App Group so the tunnel extension sees the same value.
    @Published var isEnabled: Bool = DebugLogger.sharedDefaults.bool(forKey: DebugLogger.isEnabledKey) {
        didSet { DebugLogger.sharedDefaults.set(isEnabled, forKey: DebugLogger.isEnabledKey) }
    }

    /// The log buffer. Capped at `maxEntries` to prevent unbounded memory growth.
    /// Populated from BOTH in-process `log()` calls AND `SharedDebugLogStore`
    /// (which receives mirrored writes from the tunnel extension).
    @Published private(set) var entries: [DebugLogEntry] = []

    private let maxEntries = 2000

    /// Convenience alias so call sites can still use `DebugLogger.timestampFormatter`.
    static var timestampFormatter: DateFormatter { debugTimestampFormatter }

    private init() {
        // Hydrate from the cross-process store so existing tunnel writes
        // (from a previous session or a kicked-off connect) show up
        // immediately when DebugLogView appears.
        refreshFromSharedStore()
    }

    // MARK: - Logging

    func log(_ category: DebugLogCategory, _ message: String) {
        guard isEnabled else { return }
        let entry = DebugLogEntry(
            timestamp: Date(),
            category: category,
            message: message,
            origin: "app"
        )
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }

        // Mirror to the cross-process store so the line is preserved if
        // the app is killed and so other processes (currently the
        // WireGuardTunnel extension via TunnelLog) can see it.
        SharedDebugLogStore.shared.append(SharedDebugLogEntry(
            id: entry.id,
            timestamp: entry.timestamp,
            subsystem: category.subsystemTag,
            level: "info",
            message: message
        ))
    }

    // MARK: - Convenience

    func api(_ message: String)     { log(.api, message) }
    func wg(_ message: String)      { log(.wg, message) }
    func ne(_ message: String)      { log(.ne, message) }
    func dns(_ message: String)     { log(.dns, message) }
    func peer(_ message: String)    { log(.peer, message) }
    func app(_ message: String)     { log(.app, message) }
    /// Tag for the Shadowsocks fallback flow. Tek filters on this.
    func stealth(_ message: String) { log(.stealth, message) }

    // MARK: - Cross-process merge

    /// Pull fresh entries from `SharedDebugLogStore` and re-derive the
    /// in-memory list. Called on init and whenever DebugLogView is shown.
    /// Entries from the tunnel extension get `origin = "ext"`.
    ///
    /// NOTE: this DOES NOT clear in-process state — it merges by `id` so
    /// the same line never appears twice (we use the same `id` on both
    /// sides when the main app writes).
    func refreshFromSharedStore() {
        let shared = SharedDebugLogStore.shared.readAll()
        var byId: [UUID: DebugLogEntry] = [:]

        // In-process entries first (they take precedence on collisions).
        for entry in entries {
            byId[entry.id] = entry
        }
        // Then merge in shared-store entries we haven't seen yet.
        for sharedEntry in shared {
            if byId[sharedEntry.id] != nil { continue }
            let category = DebugLogCategory(rawValue: sharedEntry.subsystem) ?? .app
            // Tunnel-side entries default to "ext" since the main app
            // always writes through `log(_:_:)` which sets "app".
            byId[sharedEntry.id] = DebugLogEntry(
                id: sharedEntry.id,
                timestamp: sharedEntry.timestamp,
                category: category,
                message: sharedEntry.message,
                origin: "ext"
            )
        }

        // Sort by timestamp, cap at maxEntries.
        var merged = Array(byId.values).sorted { $0.timestamp < $1.timestamp }
        if merged.count > maxEntries {
            merged.removeFirst(merged.count - maxEntries)
        }
        entries = merged
    }

    // MARK: - Export

    func clear() {
        entries.removeAll()
        SharedDebugLogStore.shared.clear()
    }

    /// Returns the full log as a plain-text string for clipboard/share.
    var exportText: String {
        let header = """
        WraithVPN Debug Log
        Device: \(deviceInfo)
        Exported: \(ISO8601DateFormatter().string(from: Date()))
        Entries: \(entries.count)
        ──────────────────────────────────
        """
        let body = entries.map(\.formatted).joined(separator: "\n")
        return header + "\n" + body
    }

    /// Returns a shareable log bundle as a temporary file URL.
    /// Filename format: `wraith-debug-YYYYMMDD-HHMMSS.txt` so Tek can
    /// disambiguate multiple shares in his Files / Mail attachments.
    var exportFileURL: URL? {
        let text = exportText
        let dir = FileManager.default.temporaryDirectory

        let stampFmt = DateFormatter()
        stampFmt.dateFormat = "yyyyMMdd-HHmmss"
        stampFmt.timeZone = TimeZone(secondsFromGMT: 0)
        let stamp = stampFmt.string(from: Date())

        let file = dir.appendingPathComponent("wraith-debug-\(stamp).txt")
        do {
            try text.write(to: file, atomically: true, encoding: .utf8)
            return file
        } catch {
            return nil
        }
    }

    private var deviceInfo: String {
#if canImport(UIKit)
        "\(UIDevice.current.name) / \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
#else
        "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
#endif
    }
}
