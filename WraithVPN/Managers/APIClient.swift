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
    case GET, POST, DELETE
}

private struct APIRequest {
    let method: HTTPMethod
    let path: String
    let body: (any Encodable)?
    let requiresAuth: Bool

    init(_ method: HTTPMethod, _ path: String, body: (any Encodable)? = nil, auth: Bool = false) {
        self.method = method
        self.path = path
        self.body = body
        self.requiresAuth = auth
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
        try await request(APIRequest(.GET, "/v1/servers"))
    }

    /// Returns the single best node for the caller's location.
    func fetchNearestServer() async throws -> VPNServer {
        try await request(APIRequest(.GET, "/v1/servers/nearest"))
    }

    /// Provisions a new WireGuard peer and returns the full config.
    func provisionPeer(pubkey: String, region: String?, label: String) async throws -> ProvisionResponse {
        let body = ProvisionRequest(clientPubkey: pubkey, region: region, label: label)
        return try await request(APIRequest(.POST, "/v1/peers/provision", body: body, auth: true))
    }

    /// Lists all peers provisioned for the current token.
    func fetchPeers() async throws -> [Peer] {
        try await request(APIRequest(.GET, "/v1/peers", auth: true))
    }

    /// Revokes (deletes) a provisioned peer.
    func deletePeer(peerId: String) async throws {
        let _: EmptyResponse = try await request(APIRequest(.DELETE, "/v1/peers/\(peerId)", auth: true))
    }

    /// Validates an Apple transaction and exchanges it for a subscription token.
    func validateApplePurchase(
        transactionId: String,
        originalTransactionId: String,
        productId: String,
        bundleId: String
    ) async throws -> TokenResponse {
        let body = AppleTokenRequest(
            transactionId: transactionId,
            originalTransactionId: originalTransactionId,
            productId: productId,
            bundleId: bundleId
        )
        return try await request(APIRequest(.POST, "/v1/token/validate/apple", body: body))
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

        // Encode body
        if let body = req.body {
            urlRequest.httpBody = try encoder.encode(AnyEncodable(body))
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
