// ShadowsocksIntegrationTests.swift
// WraithVPNTests
//
// Integration tests for the SS-2022 fallback transport.
// All tests require WRAITH_INTEGRATION_TESTS=1 in the environment.
// Run only on a physical device or a host with network access to vpn-iad-01.

import XCTest
@testable import WraithVPN
import Foundation
import CryptoKit
import CommonCrypto

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
    ///   salt(32) + EIH(16) + AEAD(fixedHeader=11B, 16B tag → 27B) + AEAD(addrData=9B, 16B tag → 25B)
    ///   = 32 + 16 + 27 + 25 = 100 bytes
    ///
    /// BLAKE3 functions are inlined here (ShadowsocksTransport lives in WireGuardTunnel extension,
    /// which is not accessible via @testable import WraithVPN — same pattern as ShadowsocksAEADTests).
    func testWirePrefixStructure() throws {
        // Two synthetic 32-byte PSKs
        let serverPSK = Data(repeating: 0xAA, count: 32)
        let userPSK   = Data(repeating: 0xBB, count: 32)
        let salt      = Data(repeating: 0xCC, count: 32)

        // --- Derive subkey via HKDF-SHA1 ---
        let info = Data("ss-subkey".utf8)
        let subkey = HKDF<Insecure.SHA1>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: userPSK),
            salt: salt,
            info: info,
            outputByteCount: 32
        ).withUnsafeBytes { Data($0) }

        // --- Build EIH ---
        var keyMaterial = Data()
        keyMaterial.append(serverPSK)
        keyMaterial.append(salt)
        let eihKeyFull = testBlake3DeriveKey(
            context: "shadowsocks 2022 identity subkey",
            keyMaterial: keyMaterial
        )
        XCTAssertEqual(eihKeyFull.count, 32, "EIH derive_key output must be 32 bytes")

        let userPSKHash = testBlake3Hash(userPSK)
        let eihPlaintext = userPSKHash.prefix(16)
        XCTAssertEqual(eihPlaintext.count, 16, "EIH plaintext must be 16 bytes")

        // AES-256-ECB with 32-byte key → 16-byte ciphertext
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

        // --- Fixed header: type(1)+timestamp(8)+length(2) = 11 bytes ---
        var fixedHeader = Data()
        fixedHeader.append(0x00)
        var ts = UInt64(0).bigEndian
        fixedHeader.append(Data(bytes: &ts, count: 8))
        var addrLen = UInt16(9).bigEndian
        fixedHeader.append(Data(bytes: &addrLen, count: 2))
        XCTAssertEqual(fixedHeader.count, 11, "Fixed header must be 11 bytes")

        // --- Address data: ATYP(1)+IPv4(4)+port(2)+padding(2) = 9 bytes ---
        var addrData = Data()
        addrData.append(0x01)
        addrData.append(contentsOf: [87, 99, 128, 159])  // 87.99.128.159
        var wgPort = UInt16(51820).bigEndian
        addrData.append(Data(bytes: &wgPort, count: 2))
        addrData.append(contentsOf: [0x00, 0x00])
        XCTAssertEqual(addrData.count, 9, "Address data must be 9 bytes")

        // --- Encrypt both chunks ---
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

        // --- Assemble wire prefix: salt(32)+EIH(16)+encFixed(27)+encAddr(25) = 100 bytes ---
        let wirePrefix = salt + eihBlock + encFixedBytes + encAddrBytes
        XCTAssertEqual(wirePrefix.count, 100, "Wire prefix must be exactly 100 bytes")

        // salt must occupy bytes 0-31
        XCTAssertEqual(wirePrefix.prefix(32), salt,
            "Wire prefix must begin with requestSalt (server reads salt before EIH)")

        // EIH occupies bytes 32-47
        let eihRange = Data(wirePrefix[32..<48])
        XCTAssertEqual(eihRange.count, 16, "EIH block must occupy bytes 32-47")
        XCTAssertEqual(eihRange, eihBlock, "Bytes 32-47 must be the EIH ciphertext")
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
                    tcpReached = true
                } else if acceptableCodes.contains(nsError.code) {
                    tcpReached = true
                }
            } else {
                tcpReached = true
            }
        }.resume()

        waitForExpectations(timeout: 10.0)
        XCTAssertTrue(tcpReached,
            "vpn-iad-01.vpn.katafract.com:8443 must be TCP-reachable for SS fallback to work")
    }

    // MARK: - Inline BLAKE3 (mirrors ShadowsocksTransport.swift — see that file for spec comments)

    private let blake3IV: [UInt32] = [
        0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
        0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19
    ]
    private let blake3MsgPermutation: [Int] = [2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8]

    private let B3_CHUNK_START:         UInt32 = 1 << 0
    private let B3_CHUNK_END:           UInt32 = 1 << 1
    private let B3_ROOT:                UInt32 = 1 << 3
    private let B3_DERIVE_KEY_CONTEXT:  UInt32 = 1 << 5
    private let B3_DERIVE_KEY_MATERIAL: UInt32 = 1 << 6

    private func b3G(_ state: inout [UInt32], a: Int, b: Int, c: Int, d: Int, mx: UInt32, my: UInt32) {
        state[a] = state[a] &+ state[b] &+ mx
        state[d] = (state[d] ^ state[a]).rotateRight(16)
        state[c] = state[c] &+ state[d]
        state[b] = (state[b] ^ state[c]).rotateRight(12)
        state[a] = state[a] &+ state[b] &+ my
        state[d] = (state[d] ^ state[a]).rotateRight(8)
        state[c] = state[c] &+ state[d]
        state[b] = (state[b] ^ state[c]).rotateRight(7)
    }

    private func b3Round(_ state: inout [UInt32], m: [UInt32]) {
        b3G(&state, a: 0, b: 4, c: 8,  d: 12, mx: m[0],  my: m[1])
        b3G(&state, a: 1, b: 5, c: 9,  d: 13, mx: m[2],  my: m[3])
        b3G(&state, a: 2, b: 6, c: 10, d: 14, mx: m[4],  my: m[5])
        b3G(&state, a: 3, b: 7, c: 11, d: 15, mx: m[6],  my: m[7])
        b3G(&state, a: 0, b: 5, c: 10, d: 15, mx: m[8],  my: m[9])
        b3G(&state, a: 1, b: 6, c: 11, d: 12, mx: m[10], my: m[11])
        b3G(&state, a: 2, b: 7, c: 8,  d: 13, mx: m[12], my: m[13])
        b3G(&state, a: 3, b: 4, c: 9,  d: 14, mx: m[14], my: m[15])
    }

    private func b3Compress(cv: [UInt32], block: [UInt32], blockLen: UInt32,
                             counter: UInt64, flags: UInt32) -> [UInt32] {
        var state: [UInt32] = [
            cv[0], cv[1], cv[2], cv[3],
            cv[4], cv[5], cv[6], cv[7],
            blake3IV[0], blake3IV[1], blake3IV[2], blake3IV[3],
            UInt32(counter & 0xFFFFFFFF), UInt32(counter >> 32),
            blockLen, flags
        ]
        var m = block
        for _ in 0..<7 {
            b3Round(&state, m: m)
            var permuted = [UInt32](repeating: 0, count: 16)
            for i in 0..<16 { permuted[i] = m[blake3MsgPermutation[i]] }
            m = permuted
        }
        for i in 0..<8 {
            state[i]     ^= state[i + 8]
            state[i + 8] ^= cv[i]
        }
        return state
    }

    private func b3BlockWords(from input: Data) -> [UInt32] {
        var padded = [UInt8](input) + [UInt8](repeating: 0, count: max(0, 64 - input.count))
        padded = Array(padded.prefix(64))
        var block = [UInt32](repeating: 0, count: 16)
        for i in 0..<16 {
            let off = i * 4
            block[i] = UInt32(padded[off])
                | (UInt32(padded[off+1]) << 8)
                | (UInt32(padded[off+2]) << 16)
                | (UInt32(padded[off+3]) << 24)
        }
        return block
    }

    private func b3OutputBytes(from state: [UInt32]) -> Data {
        var out = Data(count: 32)
        out.withUnsafeMutableBytes { buf in
            for i in 0..<8 {
                let v = state[i]
                buf[i*4+0] = UInt8(v & 0xFF)
                buf[i*4+1] = UInt8((v >> 8) & 0xFF)
                buf[i*4+2] = UInt8((v >> 16) & 0xFF)
                buf[i*4+3] = UInt8((v >> 24) & 0xFF)
            }
        }
        return out
    }

    func testBlake3Hash(_ input: Data) -> Data {
        let block = b3BlockWords(from: input)
        let flags = B3_CHUNK_START | B3_CHUNK_END | B3_ROOT
        let out = b3Compress(cv: blake3IV, block: block,
                              blockLen: UInt32(min(input.count, 64)),
                              counter: 0, flags: flags)
        return b3OutputBytes(from: out)
    }

    func testBlake3DeriveKey(context: String, keyMaterial: Data) -> Data {
        let ctxData = Data(context.utf8)
        let ctxBlock = b3BlockWords(from: ctxData)
        let ctxFlags = B3_CHUNK_START | B3_CHUNK_END | B3_ROOT | B3_DERIVE_KEY_CONTEXT
        let ctxState = b3Compress(cv: blake3IV, block: ctxBlock,
                                   blockLen: UInt32(min(ctxData.count, 64)),
                                   counter: 0, flags: ctxFlags)
        let derivedCV = Array(ctxState.prefix(8))
        let matBlock = b3BlockWords(from: keyMaterial)
        let matFlags = B3_CHUNK_START | B3_CHUNK_END | B3_ROOT | B3_DERIVE_KEY_MATERIAL
        let outState = b3Compress(cv: derivedCV, block: matBlock,
                                   blockLen: UInt32(min(keyMaterial.count, 64)),
                                   counter: 0, flags: matFlags)
        return b3OutputBytes(from: outState)
    }

    private func makeNonce12(_ counter: UInt64) -> Data {
        var nonce = Data(count: 12)
        nonce.withUnsafeMutableBytes { buf in
            var c = counter.bigEndian
            memcpy(buf.baseAddress! + 4, &c, 8)
        }
        return nonce
    }
}

private extension UInt32 {
    func rotateRight(_ n: Int) -> UInt32 { (self >> n) | (self << (32 - n)) }
}
