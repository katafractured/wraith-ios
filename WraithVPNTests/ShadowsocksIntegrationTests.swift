// ShadowsocksIntegrationTests.swift
// WraithVPNTests
//
// Integration tests for the SS-2022 fallback transport.
// All tests require WRAITH_INTEGRATION_TESTS=1 in the environment.
// Run only on a physical device or a host with network access to vpn-iad-01.

import XCTest
@testable import WraithVPN
import Foundation

final class ShadowsocksIntegrationTests: XCTestCase {

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["WRAITH_INTEGRATION_TESTS"] == "1" else {
            throw XCTSkip("Set WRAITH_INTEGRATION_TESTS=1 to run integration tests")
        }
    }

    // MARK: - ProvisionResponse decode (no network)

    func testProvisionResponseDecodesShadowsocksFallback() throws {
        // Verify that ProvisionResponse properly decodes the shadowsocks_fallback block
        // returned by POST /v1/peers/provision.
        let json = """
        {
            "peer_id": "test-peer-abc123",
            "config": "# This would be a WireGuard config string",
            "config_qr": null,
            "node_id": "vpn-iad-01",
            "endpoint": "87.99.128.159:51820",
            "assigned_ipv4": "10.10.6.15",
            "shadowsocks_fallback": {
                "server": "vpn-iad-01.vpn.katafract.com",
                "port": 8443,
                "method": "2022-blake3-aes-256-gcm",
                "password": "UjZyxPKMWrhIqQk/icUUVk5RH0QZCJrREQaZWahMK2s=:A4aTuxJuOX5elNa99mgNUFhrDwsIvqLLTUu82X0SEmY=",
                "plugin": "v2ray-plugin",
                "plugin_opts": "tls;host=vpn-iad-01.vpn.katafract.com"
            }
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(ProvisionResponse.self, from: json)

        XCTAssertEqual(response.peerId, "test-peer-abc123", "peer_id must decode")
        XCTAssertNotNil(response.shadowsocksFallback, "shadowsocksFallback must be decoded")

        let fb = try XCTUnwrap(response.shadowsocksFallback)
        XCTAssertEqual(fb.server, "vpn-iad-01.vpn.katafract.com")
        XCTAssertEqual(fb.port, 8443)
        XCTAssertEqual(fb.method, "2022-blake3-aes-256-gcm")
        XCTAssertEqual(fb.plugin, "v2ray-plugin")
        XCTAssertEqual(fb.pluginOpts, "tls;host=vpn-iad-01.vpn.katafract.com")
        XCTAssertTrue(fb.password.contains(":"), "Password must contain ':' PSK separator")

        // Verify the two PSK components are both valid base64
        let parts = fb.password.split(separator: ":", maxSplits: 1)
        XCTAssertEqual(parts.count, 2, "Password must have exactly two ':'-separated parts")
        let serverPSK = Data(base64Encoded: String(parts[0]))
        let userPSK = Data(base64Encoded: String(parts[1]))
        XCTAssertEqual(serverPSK?.count, 32, "Server PSK must be 32 bytes")
        XCTAssertEqual(userPSK?.count, 32, "User PSK must be 32 bytes")
    }

    // MARK: - Wire format structural assertions (no network)

    /// Verifies the SS-2022 wire prefix byte layout without any live network:
    ///   salt(32) + EIH(16) + AEAD(fixedHeader=11B, 16B tag=27B) + AEAD(addrData=9B, 16B tag=25B)
    ///   = 32 + 16 + 27 + 25 = 100 bytes
    func testWirePrefixStructure() throws {
        // Two synthetic 32-byte PSKs
        let serverPSK = Data(repeating: 0xAA, count: 32)
        let userPSK   = Data(repeating: 0xBB, count: 32)
        let password  = serverPSK.base64EncodedString() + ":" + userPSK.base64EncodedString()

        let salt = Data(repeating: 0xCC, count: 32)

        // Derive subkey
        let info = Data("ss-subkey".utf8)
        let subkey = HKDF<Insecure.SHA1>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: userPSK),
            salt: salt,
            info: info,
            outputByteCount: 32
        ).withUnsafeBytes { Data($0) }

        // Build EIH
        var keyMaterial = Data()
        keyMaterial.append(serverPSK)
        keyMaterial.append(salt)
        let eihKeyFull = blake3DeriveKey(context: "shadowsocks 2022 identity subkey", keyMaterial: keyMaterial)
        XCTAssertEqual(eihKeyFull.count, 32, "EIH derive_key output must be 32 bytes")
        let userPSKHash = blake3Hash(userPSK)
        let eihPlaintext = userPSKHash.prefix(16)
        XCTAssertEqual(eihPlaintext.count, 16, "EIH plaintext must be 16 bytes")

        // AES-256-ECB with 32-byte key
        var ciphertext = [UInt8](repeating: 0, count: 16)
        var numBytesEncrypted = 0
        let status: CCCryptorStatus = eihKeyFull.withUnsafeBytes { keyBytes in
            Data(eihPlaintext).withUnsafeBytes { ptBytes in
                CCCrypt(
                    CCOperation(kCCEncrypt),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCOptions(kCCOptionECBMode),
                    keyBytes.baseAddress, eihKeyFull.count,
                    nil,
                    ptBytes.baseAddress, 16,
                    &ciphertext, 16,
                    &numBytesEncrypted
                )
            }
        }
        XCTAssertEqual(Int32(status), Int32(kCCSuccess), "AES-256-ECB must succeed")
        XCTAssertEqual(numBytesEncrypted, 16, "EIH ciphertext must be 16 bytes")
        let eihBlock = Data(ciphertext)

        // Build fixed header (11 bytes)
        var fixedHeader = Data()
        fixedHeader.append(0x00)  // type
        var ts = UInt64(0).bigEndian
        fixedHeader.append(Data(bytes: &ts, count: 8))
        var addrLen = UInt16(9).bigEndian
        fixedHeader.append(Data(bytes: &addrLen, count: 2))
        XCTAssertEqual(fixedHeader.count, 11, "Fixed header must be 11 bytes")

        // Build address data (9 bytes)
        var addrData = Data()
        addrData.append(0x01)
        addrData.append(contentsOf: [87, 99, 128, 159])  // 87.99.128.159
        var wgPort = UInt16(51820).bigEndian
        addrData.append(Data(bytes: &wgPort, count: 2))
        addrData.append(contentsOf: [0x00, 0x00])
        XCTAssertEqual(addrData.count, 9, "Address data must be 9 bytes")

        // Encrypt both chunks
        func makeNonce12(_ counter: UInt64) -> Data {
            var n = Data(count: 12)
            n.withUnsafeMutableBytes { buf in
                var c = counter.bigEndian
                memcpy(buf.baseAddress! + 4, &c, 8)
            }
            return n
        }
        let symKey = SymmetricKey(data: subkey)
        let encFixed = try AES.GCM.seal(fixedHeader, using: symKey,
                                         nonce: try AES.GCM.Nonce(data: makeNonce12(0)),
                                         authenticating: salt)
        let encFixedBytes = Data(encFixed.ciphertext) + Data(encFixed.tag)
        XCTAssertEqual(encFixedBytes.count, 27, "Encrypted fixed header must be 11+16=27 bytes")

        let encAddr = try AES.GCM.seal(addrData, using: symKey,
                                        nonce: try AES.GCM.Nonce(data: makeNonce12(1)),
                                        authenticating: Data())
        let encAddrBytes = Data(encAddr.ciphertext) + Data(encAddr.tag)
        XCTAssertEqual(encAddrBytes.count, 25, "Encrypted address data must be 9+16=25 bytes")

        // Assemble wire prefix: salt(32) + EIH(16) + encFixed(27) + encAddr(25) = 100 bytes
        let wirePrefix = salt + eihBlock + encFixedBytes + encAddrBytes
        XCTAssertEqual(wirePrefix.count, 100, "Wire prefix must be exactly 100 bytes")

        // Verify ordering: first 32 bytes are the salt
        XCTAssertEqual(wirePrefix.prefix(32), salt, "Wire prefix must begin with requestSalt")

        // Bytes 32..47 are the EIH block
        let eihRange = wirePrefix[32..<48]
        XCTAssertEqual(eihRange.count, 16, "EIH block must occupy bytes 32-47")
    }

    // MARK: - TCP reachability (live network)

    func testShadowsocksEndpointTCPReachability() throws {
        // Verify TCP + TLS reachability to vpn-iad-01:8443.
        // The server runs ssservice+v2ray-plugin behind TLS. An HTTP request will
        // fail at the app layer (SS is not HTTP), but any response — including a TLS
        // error or reset — proves the TCP/TLS path is open.
        let url = URL(string: "https://vpn-iad-01.vpn.katafract.com:8443/")!
        var request = URLRequest(url: url, timeoutInterval: 5.0)
        request.httpMethod = "GET"

        let expectation = expectation(description: "TCP reachability")
        let session = URLSession(configuration: .ephemeral)
        var tcpReached = false

        session.dataTask(with: request) { _, _, error in
            defer { expectation.fulfill() }
            if let nsError = error as NSError? {
                // A TLS/protocol error means TCP connected successfully
                let acceptableDomains = [NSURLErrorDomain, "kCFErrorDomainCFNetwork"]
                let acceptableCodes = [
                    NSURLErrorBadServerResponse,        // got a response but not HTTP
                    NSURLErrorSecureConnectionFailed,   // TLS connected, protocol mismatch
                    NSURLErrorServerCertificateUntrusted,
                    -1200  // SSL error — connection made but cert check
                ]
                if acceptableDomains.contains(nsError.domain) &&
                   !acceptableCodes.contains(nsError.code) &&
                   nsError.code != NSURLErrorTimedOut &&
                   nsError.code != NSURLErrorCannotConnectToHost &&
                   nsError.code != NSURLErrorNetworkConnectionLost {
                    // Any error except "couldn't connect" means TCP succeeded
                    tcpReached = true
                } else if acceptableCodes.contains(nsError.code) {
                    tcpReached = true
                }
                // If timeout or can't connect → tcpReached stays false
            } else {
                // Got an HTTP response — definitely connected
                tcpReached = true
            }
        }.resume()

        waitForExpectations(timeout: 10.0)
        XCTAssertTrue(tcpReached,
            "vpn-iad-01.vpn.katafract.com:8443 must be TCP-reachable for SS fallback to work")
    }
}
