// DebugLogger.swift
// WraithVPN
//
// Founder-only trace log system. Captures API calls, WG tunnel state transitions,
// NE error codes, peer/node info, and DNS test results into a ring buffer.
// Viewable in-app and exportable as a "send to support" bundle.

import Foundation
import Combine
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Log category

enum DebugLogCategory: String {
    case api  = "API"
    case wg   = "WG"
    case ne   = "NE"
    case dns  = "DNS"
    case peer = "PEER"
    case app  = "APP"
}

// MARK: - Log entry

struct DebugLogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let category: DebugLogCategory
    let message: String

    var formatted: String {
        "[\(debugTimestampFormatter.string(from: timestamp))] [\(category.rawValue)] \(message)"
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

    /// Whether debug logging is active. Only toggleable by founder token holders.
    @Published var isEnabled: Bool = UserDefaults.standard.bool(forKey: "debugModeEnabled") {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "debugModeEnabled") }
    }

    /// The log buffer. Capped at `maxEntries` to prevent unbounded memory growth.
    @Published private(set) var entries: [DebugLogEntry] = []

    private let maxEntries = 2000

    /// Convenience alias so call sites can still use `DebugLogger.timestampFormatter`.
    static var timestampFormatter: DateFormatter { debugTimestampFormatter }

    private init() {}

    // MARK: - Logging

    func log(_ category: DebugLogCategory, _ message: String) {
        guard isEnabled else { return }
        let entry = DebugLogEntry(timestamp: Date(), category: category, message: message)
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    // MARK: - Convenience

    func api(_ message: String) { log(.api, message) }
    func wg(_ message: String)  { log(.wg, message) }
    func ne(_ message: String)  { log(.ne, message) }
    func dns(_ message: String) { log(.dns, message) }
    func peer(_ message: String) { log(.peer, message) }
    func app(_ message: String) { log(.app, message) }

    // MARK: - Export

    func clear() {
        entries.removeAll()
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
    var exportFileURL: URL? {
        let text = exportText
        let dir = FileManager.default.temporaryDirectory
        let file = dir.appendingPathComponent("wraith-debug-\(Int(Date().timeIntervalSince1970)).log")
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
