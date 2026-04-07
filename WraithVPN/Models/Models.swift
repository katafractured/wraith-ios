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

    /// Minimal stub used only to persist the provisioned nodeId across restarts.
    static func stub(nodeId: String) -> VPNServer {
        VPNServer(nodeId: nodeId, site: "", region: "", displayName: "", ipv4: "",
                  ipv6: nil, endpoints: Endpoints(primary: "", secondary: nil),
                  publicKey: "", wgPort: 0, loadScore: 0, ipv6Available: false, geodnsWeight: 0)
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
        "us-central":   ("Missouri",    "🇺🇸"),
        "us-east":      ("Virginia",   "🇺🇸"),
        "us-west":      ("Oregon",     "🇺🇸"),
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
    let assignedIpv6: String?
    let nodeId: String
    let endpoint: String

    enum CodingKeys: String, CodingKey {
        case peerId       = "peer_id"
        case config
        case configQr     = "config_qr"
        case assignedIpv4 = "assigned_ipv4"
        case assignedIpv6 = "assigned_ipv6"
        case nodeId       = "node_id"
        case endpoint
    }
}

struct SwitchPeerRequest: Encodable {
    let fromPeerId: String
    let region: String?
    let label: String
    let clientPubkey: String?

    enum CodingKeys: String, CodingKey {
        case fromPeerId   = "from_peer_id"
        case region
        case label
        case clientPubkey = "client_pubkey"
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

// MARK: - Token info (GET /v1/token/info)

struct TokenInfoResponse: Decodable {
    let plan: String
    let isFounder: Bool
    let expiresAt: String?  // nil for founders (never expire)
    let maxPeers: Int

    enum CodingKeys: String, CodingKey {
        case plan
        case isFounder = "is_founder"
        case expiresAt = "expires_at"
        case maxPeers  = "max_peers"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        plan      = try c.decode(String.self, forKey: .plan)
        isFounder = try c.decode(Bool.self,   forKey: .isFounder)
        maxPeers  = try c.decode(Int.self,    forKey: .maxPeers)
        if let ts = try? c.decode(Int.self, forKey: .expiresAt) {
            expiresAt = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
        } else {
            expiresAt = try? c.decode(String.self, forKey: .expiresAt)
        }
    }
}

// MARK: - Token validation (Apple)

struct AppleTokenRequest: Encodable {
    let transactionId: String
    let originalTransactionId: String
    let productId: String
    let bundleId: String
    let jwsTransaction: String

    enum CodingKeys: String, CodingKey {
        case transactionId         = "transaction_id"
        case originalTransactionId = "original_transaction_id"
        case productId             = "product_id"
        case bundleId              = "bundle_id"
        case jwsTransaction        = "jws_transaction"
    }
}

struct TokenResponse: Decodable {
    let token: String
    let expiresAt: String  // stored as ISO8601 string in Keychain
    let plan: String

    enum CodingKeys: String, CodingKey {
        case token
        case expiresAt = "expires_at"
        case plan
    }

    init(token: String, expiresAt: String, plan: String) {
        self.token = token
        self.expiresAt = expiresAt
        self.plan = plan
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        token = try c.decode(String.self, forKey: .token)
        plan  = try c.decode(String.self, forKey: .plan)
        // Backend returns expires_at as either a Unix timestamp (Int) or ISO8601 string
        if let ts = try? c.decode(Int.self, forKey: .expiresAt) {
            expiresAt = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
        } else {
            expiresAt = try c.decode(String.self, forKey: .expiresAt)
        }
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
        case "founder", "total", "total_annual": return "Founder"
        case "haven":                            return "Haven DNS"
        case "veil", "vpn_armor":               return "WraithVPN"
        case "vpn_armor_annual", "veil_annual":  return "WraithVPN Annual"
        case "enclave", "enclave_annual":        return "Enclave"
        default:                                 return plan
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

// MARK: - Haven DNS preferences

struct DnsPreferences: Codable {
    let tier: String
    let protectionLevel: String
    let protectionLevels: [String]
    let safeBrowsing: Bool
    let familyFilter: Bool
    let blockedServices: [String]
    let blockableServices: [String]
    let updatedAt: Int?

    var isPro: Bool { tier == "pro" || tier == "founder" }

    enum CodingKeys: String, CodingKey {
        case tier
        case protectionLevel   = "protection_level"
        case protectionLevels  = "protection_levels"
        case safeBrowsing      = "safe_browsing"
        case familyFilter      = "family_filter"
        case blockedServices   = "blocked_services"
        case blockableServices = "blockable_services"
        case updatedAt         = "updated_at"
    }
}

// MARK: - Tunnel mode

enum TunnelMode: String {
    /// All traffic routes through WireGuard. If the tunnel drops, iOS falls back to
    /// the native connection. System apps (Mail, Maps) remain functional.
    case standard
    /// OS-level kill switch. All traffic is forced through the tunnel; if it drops,
    /// there is no internet connection until the tunnel is restored.
    case full

    var displayName: String {
        switch self {
        case .standard: return "Standard"
        case .full:     return "Full (Kill Switch)"
        }
    }
}

struct DnsPreferencesUpdate: Encodable {
    var protectionLevel: String?
    var safeBrowsing: Bool?
    var familyFilter: Bool?
    var blockedServices: [String]?

    enum CodingKeys: String, CodingKey {
        case protectionLevel = "protection_level"
        case safeBrowsing    = "safe_browsing"
        case familyFilter    = "family_filter"
        case blockedServices = "blocked_services"
    }
}

// MARK: - DNS Stats (GET /v1/dns/stats)

struct DailyDNSStat: Codable, Identifiable {
    let date: String
    let queries: Int
    let blocked: Int

    var id: String { date }
}

struct DnsStatsResponse: Codable {
    let totalQueries: Int
    let adsBlocked: Int
    let trackersBlocked: Int
    let malwareBlocked: Int
    let blockedTotal: Int
    let blockRatePercent: Double
    let since: String?
    let updatedAt: String?
    let dailyHistory: [DailyDNSStat]

    enum CodingKeys: String, CodingKey {
        case totalQueries      = "total_queries"
        case adsBlocked        = "ads_blocked"
        case trackersBlocked   = "trackers_blocked"
        case malwareBlocked    = "malware_blocked"
        case blockedTotal      = "blocked_total"
        case blockRatePercent  = "block_rate_percent"
        case since
        case updatedAt         = "updated_at"
        case dailyHistory      = "daily_history"
    }
}

// MARK: - Achievements (GET /v1/dns/achievements)

struct AchievementItem: Codable, Identifiable {
    let id: String
    let title: String
    let description: String
    let icon: String          // SF Symbol name
    let unlocked: Bool
    let unlockedAt: Int?      // Unix timestamp

    enum CodingKeys: String, CodingKey {
        case id, title, description, icon, unlocked
        case unlockedAt = "unlocked_at"
    }
}

struct AchievementsResponse: Codable {
    let achievements: [AchievementItem]
    let activeStreakDays: Int
    let longestStreakDays: Int

    enum CodingKeys: String, CodingKey {
        case achievements
        case activeStreakDays  = "active_streak_days"
        case longestStreakDays = "longest_streak_days"
    }
}

// MARK: - Platform Status (GET /v1/status)

struct PlatformStatus: Codable {
    let status: String        // "healthy" | "degraded" | "down"
    let totalNodes: Int
    let healthyNodes: Int
    let degradedNodes: Int
    let uptimePct: Double

    enum CodingKeys: String, CodingKey {
        case status
        case totalNodes    = "total_nodes"
        case healthyNodes  = "healthy_nodes"
        case degradedNodes = "degraded_nodes"
        case uptimePct     = "uptime_pct"
    }

    var displayStatus: String {
        switch status {
        case "healthy":  return "All Systems Operational"
        case "degraded": return "Partial Degradation"
        default:         return "Service Disruption"
        }
    }

    var isHealthy: Bool { status == "healthy" }
    var isDegraded: Bool { status == "degraded" }
}

// MARK: - Token Recovery

struct RecoveryInitResponse: Codable {
    let recoveryToken: String
    let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case recoveryToken = "recovery_token"
        case expiresIn     = "expires_in"
    }
}

// MARK: - Seats (POST /v1/token/seats/add)

struct SeatsAddRequest: Encodable {
    let jwsTransaction:        String
    let productId:             String
    let transactionId:         String
    let originalTransactionId: String
    let bundleId:              String

    enum CodingKeys: String, CodingKey {
        case jwsTransaction        = "jws_transaction"
        case productId             = "product_id"
        case transactionId         = "transaction_id"
        case originalTransactionId = "original_transaction_id"
        case bundleId              = "bundle_id"
    }
}

struct SeatsAddResponse: Decodable {
    let maxPeers:      Int
    let added:         Int
    let alreadyApplied: Bool

    enum CodingKeys: String, CodingKey {
        case maxPeers       = "max_peers"
        case added
        case alreadyApplied = "already_applied"
    }
}

// MARK: - Identity link (POST /v1/token/identity/link)

struct IdentityLinkRequest: Encodable {
    let identityType:  String
    let identityValue: String

    enum CodingKeys: String, CodingKey {
        case identityType  = "identity_type"
        case identityValue = "identity_value"
    }
}

struct IdentityLinkResponse: Decodable {
    let linked:       Bool
    let identityType: String

    enum CodingKeys: String, CodingKey {
        case linked
        case identityType = "identity_type"
    }
}
