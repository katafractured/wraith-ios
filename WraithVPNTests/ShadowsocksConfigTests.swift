// ShadowsocksConfigTests.swift
// WraithVPNTests
//
// Unit tests for ShadowsocksConfig Codable and TransportMode enum.
// Simulator-runnable tests for model shape validation.

import XCTest
@testable import WraithVPN

final class ShadowsocksConfigTests: XCTestCase {

    func testRoundtripCodable() throws {
        let cfg = ShadowsocksConfig(
            server: "vpn-iad-01.vpn.katafract.com",
            port: 8443,
            method: "2022-blake3-aes-256-gcm",
            password: "SERVER_PSK_b64:USER_PSK_b64",
            plugin: "v2ray-plugin",
            pluginOpts: "tls;host=vpn-iad-01.vpn.katafract.com"
        )
        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(ShadowsocksConfig.self, from: data)
        XCTAssertEqual(cfg, decoded)
    }

    func testDecodeFromAPIShape() throws {
        let json = """
        {
          "server": "vpn-iad-01.vpn.katafract.com",
          "port": 8443,
          "method": "2022-blake3-aes-256-gcm",
          "password": "abc:def",
          "plugin": "v2ray-plugin",
          "plugin_opts": "tls;host=vpn-iad-01.vpn.katafract.com"
        }
        """.data(using: .utf8)!
        let cfg = try JSONDecoder().decode(ShadowsocksConfig.self, from: json)
        XCTAssertEqual(cfg.pluginOpts, "tls;host=vpn-iad-01.vpn.katafract.com")
        XCTAssertEqual(cfg.port, 8443)
    }

    func testTransportModePersistencePreference() throws {
        XCTAssertEqual(TransportMode.wireguard.rawValue, "wireguard")
        XCTAssertEqual(TransportMode.shadowsocks.rawValue, "shadowsocks")
        let modes = TransportMode.allCases
        XCTAssertEqual(modes.count, 2)
    }
}
