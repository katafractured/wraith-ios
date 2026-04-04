// Models.swift
// WraithVPN
//
// Core data models matching the WraithVPN API contract.

import Foundation

// MARK: - Server / Node

struct VPNServer: Codable, Identifiable, Hashable {
    let nodeId: String
    let site: String
    let region: String
    let displayName: String
    let ipv4: String
    let ipv6: String?
    let endpoints: Endpoints
    let publicKey: String
    let wgPort: Int
    let loadScore: Double
    let ipv6Available: Bool
    let geodnsWeight: Int

    var id: String { nodeId }

    struct Endpoints: Codable, Hashable {
        let primary: String
        let secondary: String?
    }

    enum CodingKeys: String, CodingKey {
        case nodeId       = "node_id"
        case site
        case region
        case displayName  = "display_name"
        case ipv4
        case ipv6
        case endpoints
        case publicKey    = "public_key"
        case wgPort       = "wg_port"
        case loadScore    = "load_score"
        case ipv6Available = "ipv6_available"
        case geodnsWeight  = "geodns_weight"
    }

    // Human-readable city name for the UI (falls back to displayName)
    var cityName: String {
        RegionInfo.cityName(for: region)
    }

    var flagEmoji: String {
        RegionInfo.flag(for: region)
    }
}

// MARK: - Region metadata

enum RegionInfo {
    static let regionMap: [String: (city: String, flag: String)] = [
        "eu-west":      ("Frankfurt",  "🇩🇪"),
        "eu-north":     ("Helsinki",   "🇫🇮"),
        "ap-southeast": ("Singapore",  "🇸🇬"),
        "us-central":   ("US Central", "🇺🇸"),
    ]

    static func cityName(for region: String) -> String {
        regionMap[region]?.city ?? region
    }

    static func flag(for region: String) -> String {
        regionMap[region]?.flag ?? "🌐"
    }
}

// MARK: - Peer provision

struct ProvisionRequest: Encodable {
    let clientPubkey: String
    let region: String?
    let label: String

    enum CodingKeys: String, CodingKey {
        case clientPubkey = "client_pubkey"
        case region
        case label
    }
}

struct ProvisionResponse: Decodable {
    let peerId: String
    let config: String        // Full WireGuard INI config text
    let configQr: String?     // Base64 PNG QR code (optional)
    let assignedIpv4: String
    let nodeId: String
    let endpoint: String

    enum CodingKeys: String, CodingKey {
        case peerId       = "peer_id"
        case config
        case configQr     = "config_qr"
        case assignedIpv4 = "assigned_ipv4"
        case nodeId       = "node_id"
        case endpoint
    }
}

// MARK: - Peer list

struct Peer: Codable, Identifiable {
    let peerId: String
    let nodeId: String
    let assignedIpv4: String
    let label: String
    let createdAt: Int          // Unix timestamp (seconds)

    var id: String { peerId }

    var createdAtDate: Date { Date(timeIntervalSince1970: TimeInterval(createdAt)) }

    enum CodingKeys: String, CodingKey {
        case peerId       = "peer_id"
        case nodeId       = "node_id"
        case assignedIpv4 = "assigned_ipv4"
        case label
        case createdAt    = "created_at"
    }
}

struct PeerListResponse: Decodable {
    let peers: [Peer]
    let used: Int
    let limit: Int
    let canAdd: Bool

    enum CodingKeys: String, CodingKey {
        case peers, used, limit
        case canAdd = "can_add"
    }
}

// MARK: - Token validation (Apple)

struct AppleTokenRequest: Encodable {
    let transactionId: String
    let originalTransactionId: String
    let productId: String
    let bundleId: String

    enum CodingKeys: String, CodingKey {
        case transactionId         = "transaction_id"
        case originalTransactionId = "original_transaction_id"
        case productId             = "product_id"
        case bundleId              = "bundle_id"
    }
}

struct TokenResponse: Decodable {
    let token: String
    let expiresAt: String
    let plan: String

    enum CodingKeys: String, CodingKey {
        case token
        case expiresAt = "expires_at"
        case plan
    }
}

// MARK: - VPN connection state

enum VPNStatus: Equatable {
    case disconnected
    case connecting
    case connected
    case disconnecting
    case failed(String)

    var isActive: Bool {
        self == .connected || self == .connecting
    }

    var label: String {
        switch self {
        case .disconnected:    return "Disconnected"
        case .connecting:      return "Connecting…"
        case .connected:       return "Connected"
        case .disconnecting:   return "Disconnecting…"
        case .failed(let msg): return "Error: \(msg)"
        }
    }

    var color: AppColor {
        switch self {
        case .connected:    return .connected
        case .connecting,
             .disconnecting: return .connecting
        default:            return .disconnected
        }
    }
}

// MARK: - App colour tokens (resolved at render time)

enum AppColor {
    case connected
    case connecting
    case disconnected
}

// MARK: - Subscription plan

struct SubscriptionInfo: Equatable {
    let plan: String
    let expiresAt: Date?
    let token: String

    var planDisplayName: String {
        switch plan {
        case "vpn_armor":         return "WraithVPN (Monthly)"
        case "vpn_armor_annual":  return "WraithVPN (Annual)"
        default:                  return plan
        }
    }

    var isExpired: Bool {
        guard let exp = expiresAt else { return false }
        return exp < Date()
    }

    var expiryFormatted: String {
        guard let exp = expiresAt else { return "Unknown" }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: exp)
    }
}

// MARK: - Latency result

struct ServerLatency: Identifiable {
    let server: VPNServer
    let milliseconds: Double?   // nil = unreachable

    var id: String { server.nodeId }

    var displayLatency: String {
        guard let ms = milliseconds else { return "—" }
        return "\(Int(ms)) ms"
    }

    var latencyTier: LatencyTier {
        guard let ms = milliseconds else { return .unknown }
        switch ms {
        case ..<60:   return .excellent
        case ..<120:  return .good
        case ..<200:  return .fair
        default:      return .poor
        }
    }
}

enum LatencyTier {
    case excellent, good, fair, poor, unknown

    var colorHex: String {
        switch self {
        case .excellent: return "#22c55e"
        case .good:      return "#86efac"
        case .fair:      return "#facc15"
        case .poor:      return "#f87171"
        case .unknown:   return "#6b7280"
        }
    }
}
