// APIClientTests.swift
// WraithVPNTests
//
// Tests for APIError descriptions and JSON decoding contracts.
// Network calls are intercepted via MockURLProtocol.

import XCTest
@testable import WraithVPN

final class APIClientTests: XCTestCase {

    // MARK: - APIError descriptions

    func testAPIError_noToken_hasDescription() {
        let error = APIError.noToken
        XCTAssertNotNil(error.errorDescription)
        XCTAssertFalse(error.errorDescription!.isEmpty)
    }

    func testAPIError_invalidURL_hasDescription() {
        let error = APIError.invalidURL
        XCTAssertNotNil(error.errorDescription)
        XCTAssertFalse(error.errorDescription!.isEmpty)
    }

    func testAPIError_noData_hasDescription() {
        let error = APIError.noData
        XCTAssertNotNil(error.errorDescription)
        XCTAssertFalse(error.errorDescription!.isEmpty)
    }

    func testAPIError_httpError_includesStatusCode() {
        let error = APIError.httpError(statusCode: 401, body: "Unauthorized")
        let desc = error.errorDescription ?? ""
        XCTAssertTrue(desc.contains("401"), "Expected status code in: \(desc)")
    }

    func testAPIError_httpError_includesBody() {
        let error = APIError.httpError(statusCode: 500, body: "Internal Server Error")
        let desc = error.errorDescription ?? ""
        XCTAssertTrue(desc.contains("500"), "Expected status code in: \(desc)")
    }

    func testAPIError_decodingError_hasDescription() {
        struct Dummy: Decodable {}
        do {
            _ = try JSONDecoder().decode(Dummy.self, from: Data("bad".utf8))
        } catch {
            let apiError = APIError.decodingError(error)
            XCTAssertNotNil(apiError.errorDescription)
        }
    }

    // MARK: - Model JSON decoding contracts

    func testVPNServer_decodesFromJSON() throws {
        let json = """
        {
            "node_id": "node-sin-01",
            "site": "Singapore",
            "region": "ap-southeast",
            "display_name": "Singapore — AP Southeast",
            "ipv4": "5.223.52.75",
            "ipv6": null,
            "endpoints": { "primary": "5.223.52.75:51820", "secondary": null },
            "public_key": "abc123pubkey==",
            "wg_port": 51820,
            "load_score": 0.3,
            "ipv6_available": false,
            "geodns_weight": 100
        }
        """.data(using: .utf8)!
        let server = try JSONDecoder().decode(VPNServer.self, from: json)
        XCTAssertEqual(server.nodeId,      "node-sin-01")
        XCTAssertEqual(server.region,      "ap-southeast")
        XCTAssertEqual(server.ipv4,        "5.223.52.75")
        XCTAssertEqual(server.wgPort,      51820)
        XCTAssertEqual(server.cityName,    "Singapore")
        XCTAssertEqual(server.flagEmoji,   "🇸🇬")
        XCTAssertNil(server.ipv6)
    }

    func testPlatformStatus_decodesFromJSON() throws {
        let json = """
        {
            "status": "healthy",
            "total_nodes": 6,
            "healthy_nodes": 6,
            "degraded_nodes": 0,
            "uptime_pct": 99.98
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        let status = try decoder.decode(PlatformStatus.self, from: json)
        XCTAssertEqual(status.status,       "healthy")
        XCTAssertEqual(status.totalNodes,   6)
        XCTAssertEqual(status.healthyNodes, 6)
        XCTAssertTrue(status.isHealthy)
        XCTAssertFalse(status.isDegraded)
    }

    func testDnsPreferences_decodesFromJSON() throws {
        let json = """
        {
            "tier": "founder",
            "protection_level": "HIGH",
            "protection_levels": ["NONE","LOW","STANDARD","HIGH","FAMILY"],
            "safe_browsing": true,
            "family_filter": false,
            "blocked_services": ["tiktok"],
            "blockable_services": ["youtube","tiktok","instagram"],
            "updated_at": 1700000000
        }
        """.data(using: .utf8)!
        let prefs = try JSONDecoder().decode(DnsPreferences.self, from: json)
        XCTAssertEqual(prefs.tier,             "founder")
        XCTAssertEqual(prefs.protectionLevel,  "HIGH")
        XCTAssertTrue(prefs.isPro)
        XCTAssertTrue(prefs.safeBrowsing)
        XCTAssertFalse(prefs.familyFilter)
        XCTAssertEqual(prefs.blockedServices,  ["tiktok"])
    }

    func testDnsPreferences_free_isNotPro() throws {
        let json = """
        {
            "tier": "free",
            "protection_level": "LOW",
            "protection_levels": ["NONE","LOW"],
            "safe_browsing": false,
            "family_filter": false,
            "blocked_services": [],
            "blockable_services": []
        }
        """.data(using: .utf8)!
        let prefs = try JSONDecoder().decode(DnsPreferences.self, from: json)
        XCTAssertFalse(prefs.isPro)
    }

    func testProvisionResponse_decodesFromJSON() throws {
        let json = """
        {
            "peer_id": "peer-abc123",
            "config": "[Interface]\\nPrivateKey = ...",
            "config_qr": null,
            "assigned_ipv4": "10.10.1.5",
            "assigned_ipv6": null,
            "node_id": "node-eu-01",
            "endpoint": "178.104.49.211:51820"
        }
        """.data(using: .utf8)!
        let resp = try JSONDecoder().decode(ProvisionResponse.self, from: json)
        XCTAssertEqual(resp.peerId,       "peer-abc123")
        XCTAssertEqual(resp.nodeId,       "node-eu-01")
        XCTAssertEqual(resp.assignedIpv4, "10.10.1.5")
        XCTAssertNil(resp.assignedIpv6)
    }

    func testAchievementsResponse_decodesFromJSON() throws {
        let json = """
        {
            "achievements": [
                {
                    "id": "first_block",
                    "title": "First Block",
                    "description": "Blocked your first ad",
                    "icon": "shield.fill",
                    "unlocked": true,
                    "unlocked_at": 1700000000
                }
            ],
            "active_streak_days": 7,
            "longest_streak_days": 30
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        let resp = try decoder.decode(AchievementsResponse.self, from: json)
        XCTAssertEqual(resp.achievements.count,   1)
        XCTAssertEqual(resp.activeStreakDays,      7)
        XCTAssertEqual(resp.longestStreakDays,     30)
        XCTAssertTrue(resp.achievements[0].unlocked)
        XCTAssertEqual(resp.achievements[0].id,   "first_block")
    }

    func testDnsStatsResponse_decodesFromJSON() throws {
        let json = """
        {
            "total_queries": 10000,
            "ads_blocked": 1200,
            "trackers_blocked": 800,
            "malware_blocked": 50,
            "blocked_total": 2050,
            "block_rate_percent": 20.5,
            "since": "2025-01-01T00:00:00Z",
            "updated_at": "2025-06-01T12:00:00Z",
            "daily_history": [
                { "date": "2025-06-01", "queries": 500, "blocked": 100 }
            ]
        }
        """.data(using: .utf8)!
        let stats = try JSONDecoder().decode(DnsStatsResponse.self, from: json)
        XCTAssertEqual(stats.totalQueries,      10000)
        XCTAssertEqual(stats.blockedTotal,       2050)
        XCTAssertEqual(stats.blockRatePercent,   20.5, accuracy: 0.001)
        XCTAssertEqual(stats.dailyHistory.count, 1)
        XCTAssertEqual(stats.dailyHistory[0].date, "2025-06-01")
    }

    func testVPNServer_arrayDecoding() throws {
        let json = """
        [
            {
                "node_id": "node-1", "site": "EU", "region": "eu-west",
                "display_name": "EU West", "ipv4": "1.1.1.1", "ipv6": null,
                "endpoints": { "primary": "1.1.1.1:51820" },
                "public_key": "k1==", "wg_port": 51820, "load_score": 0.1,
                "ipv6_available": false, "geodns_weight": 100
            },
            {
                "node_id": "node-2", "site": "US", "region": "us-west",
                "display_name": "US West", "ipv4": "2.2.2.2", "ipv6": null,
                "endpoints": { "primary": "2.2.2.2:51820" },
                "public_key": "k2==", "wg_port": 51820, "load_score": 0.2,
                "ipv6_available": false, "geodns_weight": 100
            }
        ]
        """.data(using: .utf8)!
        let servers = try JSONDecoder().decode([VPNServer].self, from: json)
        XCTAssertEqual(servers.count, 2)
        XCTAssertEqual(servers[0].nodeId, "node-1")
        XCTAssertEqual(servers[1].nodeId, "node-2")
    }
}
