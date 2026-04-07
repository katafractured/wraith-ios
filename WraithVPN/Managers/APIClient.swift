// APIClient.swift
// WraithVPN
//
// Typed async/await HTTP client for the WraithVPN API.
// All requests go through the single `request(_:)` method so auth headers,
// decoding, and error handling are applied consistently.

import Foundation

// MARK: - Errors

enum APIError: LocalizedError {
    case invalidURL
    case noData
    case httpError(statusCode: Int, body: String)
    case decodingError(Error)
    case noToken

    var errorDescription: String? {
        switch self {
        case .invalidURL:                 return "Invalid URL"
        case .noData:                     return "Empty response"
        case .httpError(let c, let b):    return "HTTP \(c): \(b)"
        case .decodingError(let e):       return "Decode error: \(e.localizedDescription)"
        case .noToken:                    return "No subscription token found. Please subscribe first."
        }
    }
}

// MARK: - Request descriptor

private enum HTTPMethod: String {
    case GET, POST, PUT, DELETE
}

private struct APIRequest {
    let method: HTTPMethod
    let path: String
    let body: (any Encodable)?
    let requiresAuth: Bool
    let extraHeaders: [String: String]
    let timeoutInterval: TimeInterval?

    init(_ method: HTTPMethod, _ path: String, body: (any Encodable)? = nil, auth: Bool = false, extraHeaders: [String: String] = [:], timeout: TimeInterval? = nil) {
        self.method = method
        self.path = path
        self.body = body
        self.requiresAuth = auth
        self.extraHeaders = extraHeaders
        self.timeoutInterval = timeout
    }
}

// MARK: - Client

final class APIClient {

    // MARK: Singleton

    static let shared = APIClient()
    private init() {}

    // MARK: Configuration

    private let baseURL = URL(string: "https://api.katafract.com")!
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    // MARK: - Public API

    /// Returns the full list of healthy VPN nodes.
    func fetchServers() async throws -> [VPNServer] {
        try await request(APIRequest(.GET, "/v1/servers", auth: true))
    }

    /// Returns the single best node for the caller's location.
    func fetchNearestServer() async throws -> VPNServer {
        try await request(APIRequest(.GET, "/v1/servers/nearest", auth: true))
    }

    /// Provisions a new WireGuard peer and returns the full config.
    func provisionPeer(pubkey: String, region: String?, nodeId: String? = nil, label: String) async throws -> ProvisionResponse {
        let body = ProvisionRequest(clientPubkey: pubkey, region: region, nodeId: nodeId, label: label)
        return try await request(APIRequest(.POST, "/v1/peers/provision", body: body, auth: true))
    }

    /// Atomically revokes an existing peer and provisions a new one on a different node.
    /// Uses the same device slot — does not consume an additional seat.
    func switchPeer(fromPeerId: String, pubkey: String, region: String?, nodeId: String? = nil, label: String) async throws -> ProvisionResponse {
        let body = SwitchPeerRequest(fromPeerId: fromPeerId, region: region, nodeId: nodeId, label: label, clientPubkey: pubkey)
        return try await request(APIRequest(.POST, "/v1/peers/switch", body: body, auth: true))
    }

    /// Lists all peers provisioned for the current token.
    func fetchPeers() async throws -> PeerListResponse {
        try await request(APIRequest(.GET, "/v1/peers", auth: true))
    }

    /// Revokes (deletes) a provisioned peer.
    func deletePeer(peerId: String) async throws {
        let _: EmptyResponse = try await request(APIRequest(.DELETE, "/v1/peers/\(peerId)", auth: true))
    }

    /// Validates an existing subscription token and returns its info.
    /// Used on macOS to activate via a token from connect.katafract.com or iOS.
    func validateToken(_ token: String) async throws -> TokenInfoResponse {
        return try await request(APIRequest(.GET, "/v1/token/info", auth: false, extraHeaders: ["Authorization": "Bearer \(token)"]))
    }

    /// Validates an Apple transaction and exchanges it for a subscription token.
    func validateApplePurchase(
        transactionId: String,
        originalTransactionId: String,
        productId: String,
        bundleId: String,
        jwsTransaction: String
    ) async throws -> TokenResponse {
        let body = AppleTokenRequest(
            transactionId: transactionId,
            originalTransactionId: originalTransactionId,
            productId: productId,
            bundleId: bundleId,
            jwsTransaction: jwsTransaction
        )
        return try await request(APIRequest(.POST, "/v1/token/validate/apple", body: body))
    }

    /// Fetches the current DNS preferences for the token.
    func fetchDnsPreferences() async throws -> DnsPreferences {
        return try await request(APIRequest(.GET, "/v1/dns/preferences", auth: true))
    }

    /// Updates DNS preferences for the token.
    func updateDnsPreferences(_ update: DnsPreferencesUpdate) async throws -> DnsPreferences {
        return try await request(APIRequest(.PUT, "/v1/dns/preferences", body: update, auth: true))
    }

    /// Returns 30-day rolling DNS query statistics for the current token.
    func fetchDnsStats() async throws -> DnsStatsResponse {
        try await request(APIRequest(.GET, "/v1/dns/stats", auth: true))
    }

    /// Returns Haven DNS achievements and streak info for the current token.
    func fetchAchievements() async throws -> AchievementsResponse {
        try await request(APIRequest(.GET, "/v1/dns/achievements", auth: true))
    }

    /// Returns platform node health summary (public, no auth required).
    func fetchPlatformStatus() async throws -> PlatformStatus {
        // 5-second hard timeout — status is a health check, not a data fetch.
        try await request(APIRequest(.GET, "/v1/status", timeout: 5))
    }

    /// Initiates email-based token recovery for Stripe subscribers.
    /// Returns a short-lived recovery_token on success.
    func recoverByEmail(_ email: String) async throws -> RecoveryInitResponse {
        struct Body: Encodable { let email: String }
        return try await request(APIRequest(.POST, "/v1/store/recover", body: Body(email: email)))
    }

    /// Redeems a recovery token (kfr_...) and returns the subscription TokenResponse.
    func redeemRecoveryToken(_ token: String) async throws -> TokenResponse {
        try await request(APIRequest(.GET, "/v1/token/recover/\(token)"))
    }

    /// Validates an Apple seat-pack consumable IAP and adds seats to the token.
    func addSeats(
        jwsTransaction: String,
        productId: String,
        transactionId: String,
        originalTransactionId: String,
        bundleId: String
    ) async throws -> SeatsAddResponse {
        let body = SeatsAddRequest(
            jwsTransaction:        jwsTransaction,
            productId:             productId,
            transactionId:         transactionId,
            originalTransactionId: originalTransactionId,
            bundleId:              bundleId
        )
        return try await request(APIRequest(.POST, "/v1/token/seats/add", body: body, auth: true))
    }

    /// Links a recovery identity (email, apple_id, phone) to the current token.
    func linkIdentity(type identityType: String, value identityValue: String) async throws -> IdentityLinkResponse {
        let body = IdentityLinkRequest(identityType: identityType, identityValue: identityValue)
        return try await request(APIRequest(.POST, "/v1/token/identity/link", body: body, auth: true))
    }

    // MARK: - Private core

    private func request<T: Decodable>(_ req: APIRequest) async throws -> T {
        let url = baseURL.appendingPathComponent(req.path)
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = req.method.rawValue
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("WraithVPN/1.0 (iOS)", forHTTPHeaderField: "User-Agent")

        // Attach bearer token when required
        if req.requiresAuth {
            guard let token = KeychainHelper.shared.readOptional(for: .subscriptionToken) else {
                throw APIError.noToken
            }
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        // Extra headers (e.g. token validation with explicit Bearer)
        for (key, value) in req.extraHeaders {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        // Encode body
        if let body = req.body {
            urlRequest.httpBody = try encoder.encode(AnyEncodable(body))
        }

        if let t = req.timeoutInterval {
            urlRequest.timeoutInterval = t
        }

        let (data, response) = try await session.data(for: urlRequest)

        guard let http = response as? HTTPURLResponse else { throw APIError.noData }

        guard (200..<300).contains(http.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? "<binary>"
            throw APIError.httpError(statusCode: http.statusCode, body: bodyStr)
        }

        // Handle empty body (DELETE etc.)
        if T.self == EmptyResponse.self {
            return EmptyResponse() as! T
        }

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decodingError(error)
        }
    }
}

// MARK: - Helpers

/// Sentinel used for void responses (e.g. DELETE).
private struct EmptyResponse: Decodable {}

/// Type-erasing Encodable box so we can call encode() on protocol existentials.
private struct AnyEncodable: Encodable {
    private let _encode: (Encoder) throws -> Void

    init(_ value: any Encodable) {
        _encode = { try value.encode(to: $0) }
    }

    func encode(to encoder: Encoder) throws {
        try _encode(encoder)
    }
}
