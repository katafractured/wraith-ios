// DebugLogStore.swift
// WraithVPN
//
// Cross-process ring buffer for in-app debug logs. Both the main app and the
// WireGuardTunnel extension write here through their respective wrappers
// (`DebugLogger.shared` and `TunnelLog`). The Settings → Diagnostics screen
// reads from this store so Tek can grab Stealth-attempt logs from his iPhone
// without USB + Console.app.
//
// Storage: line-delimited JSON in the shared App Group container, capped at
// 1000 entries (approx. ~250 KB). NSLock guards concurrent writes from the
// main app (@MainActor) and the tunnel process (NEPacketTunnelProvider on
// its own dispatch queue).
//
// Privacy: callers MUST hash/truncate sensitive values BEFORE handing them to
// the store — see `Redact` helpers below. The store does no scrubbing of its
// own.

import Foundation

// MARK: - Shared App Group identifier

/// App Group shared between WraithVPN, WireGuardTunnel, and the macOS variants.
/// Chosen because all four targets already declare it in their entitlements
/// (`group.com.katafract.wraith` is the wraith-internal IPC group; `enclave`
/// is the cross-app group used by Vault and other Katafract apps).
enum DiagnosticsAppGroup {
    static let identifier = "group.com.katafract.wraith"
}

// MARK: - Shared entry

/// One log line. Codable so it survives the cross-process file boundary.
struct SharedDebugLogEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    /// Subsystem tag used both for filtering and for visual grouping.
    /// Free-form so future subsystems can be added without DTO migration.
    let subsystem: String
    /// Severity level: "debug", "info", "warning", "error".
    let level: String
    let message: String

    init(id: UUID = UUID(),
         timestamp: Date = Date(),
         subsystem: String,
         level: String,
         message: String) {
        self.id = id
        self.timestamp = timestamp
        self.subsystem = subsystem
        self.level = level
        self.message = message
    }
}

// MARK: - Cross-process store

/// File-backed ring buffer. Uses an `NSLock` for in-process serialization and
/// atomic file replacement for cross-process safety.
final class SharedDebugLogStore: @unchecked Sendable {

    static let shared = SharedDebugLogStore()

    /// Max entries kept on disk. Beyond this we drop the oldest.
    private let maxEntries = 1000

    /// In-process lock — protects the file read/modify/write cycle.
    private let lock = NSLock()

    /// JSON encoder/decoder with ISO-8601 timestamps for forward-compat.
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// File location inside the App Group container. Falls back to
    /// `tmp` if the App Group is unavailable (entitlement misconfig) — in
    /// that case writes are local only and the diag screen will only see the
    /// main-app entries. We never crash on missing entitlements.
    /// Computed eagerly in `init` so concurrent first-access races (lazy
    /// stored properties on a class are NOT thread-safe in Swift) can't
    /// double-init the URL.
    private let fileURL: URL?

    private init() {
        if let containerURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: DiagnosticsAppGroup.identifier) {
            self.fileURL = containerURL.appendingPathComponent("wraith-debug-log.ndjson")
        } else {
            // Fallback: temp dir. Cross-process sharing is lost.
            self.fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("wraith-debug-log.ndjson")
        }
    }

    // MARK: - Append

    /// Append a single entry. Trims the on-disk buffer if it exceeds `maxEntries`.
    /// Safe to call from any thread / any process.
    func append(_ entry: SharedDebugLogEntry) {
        guard let url = fileURL else { return }
        lock.lock()
        defer { lock.unlock() }

        var entries = readLocked(url: url)
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        writeLocked(entries: entries, url: url)
    }

    /// Read all entries, oldest first.
    func readAll() -> [SharedDebugLogEntry] {
        guard let url = fileURL else { return [] }
        lock.lock()
        defer { lock.unlock() }
        return readLocked(url: url)
    }

    /// Wipe the buffer.
    func clear() {
        guard let url = fileURL else { return }
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Locked helpers (caller MUST hold `lock`)

    private func readLocked(url: URL) -> [SharedDebugLogEntry] {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return []
        }
        // NDJSON: one entry per line. Skip malformed lines silently.
        var out: [SharedDebugLogEntry] = []
        out.reserveCapacity(maxEntries)
        for raw in data.split(separator: 0x0A) {
            if let entry = try? decoder.decode(SharedDebugLogEntry.self, from: Data(raw)) {
                out.append(entry)
            }
        }
        return out
    }

    private func writeLocked(entries: [SharedDebugLogEntry], url: URL) {
        var blob = Data()
        blob.reserveCapacity(entries.count * 256)
        for entry in entries {
            guard let line = try? encoder.encode(entry) else { continue }
            blob.append(line)
            blob.append(0x0A)  // newline
        }
        // Atomic write — protects against concurrent reader truncation.
        try? blob.write(to: url, options: .atomic)
    }
}

// MARK: - Privacy helpers

/// Tiny redaction utilities used by both the main app and the tunnel side.
/// Never let a raw token, IP, or peer pubkey hit `SharedDebugLogStore` —
/// pass it through `Redact.tail4` or `Redact.hash8` first.
enum Redact {
    /// Last 4 chars of any string. Returns "<short>" if the input is too short
    /// to redact meaningfully (avoids false confidence that "ab" is private).
    static func tail4(_ s: String?) -> String {
        guard let s, s.count >= 8 else { return "<short>" }
        return "…\(s.suffix(4))"
    }

    /// First 4 + last 4 — useful for IPs / hostnames where prefix matters.
    /// "vpn-iad-01.katafract.com" → "vpn-…t.com"
    static func ends(_ s: String?) -> String {
        guard let s, s.count >= 10 else { return "<short>" }
        return "\(s.prefix(4))…\(s.suffix(4))"
    }

    /// Stable 8-char hash of a string — for correlating without exposing
    /// the value. Good for peer pubkeys and tokens.
    static func hash8(_ s: String?) -> String {
        guard let s, !s.isEmpty else { return "<empty>" }
        var hasher = Hasher()
        hasher.combine(s)
        let h = hasher.finalize()
        return String(format: "h:%08x", UInt32(truncatingIfNeeded: h))
    }
}
