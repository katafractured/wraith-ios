// ShadowsocksAEADTests.swift
// WraithVPNTests
//
// Unit tests for SS-2022 crypto primitives used in ShadowsocksTransport.
// ShadowsocksTransport.swift compiles into WireGuardTunnel (a separate app extension
// target), so these tests duplicate the relevant crypto inline.
// All tests are simulator-runnable with no network required.

import XCTest
import CryptoKit
import CommonCrypto

final class ShadowsocksAEADTests: XCTestCase {

    // MARK: - AES-128-ECB (used in EIH block construction)

    func testAES128ECBKnownVector() throws {
        // NIST FIPS 197 AES-128 ECB test vector
        // Key:       2b7e151628aed2a6abf7158809cf4f3c
        // Plaintext: 6bc1bee22e409f96e93d7e117393172a
        // Ciphertext:3ad77bb40d7a3660a89ecaf32466ef97
        let key = Data([
            0x2b, 0x7e, 0x15, 0x16, 0x28, 0xae, 0xd2, 0xa6,
            0xab, 0xf7, 0x15, 0x88, 0x09, 0xcf, 0x4f, 0x3c
        ])
        let plaintext = Data([
            0x6b, 0xc1, 0xbe, 0xe2, 0x2e, 0x40, 0x9f, 0x96,
            0xe9, 0x3d, 0x7e, 0x11, 0x73, 0x93, 0x17, 0x2a
        ])
        let expectedCiphertext = Data([
            0x3a, 0xd7, 0x7b, 0xb4, 0x0d, 0x7a, 0x36, 0x60,
            0xa8, 0x9e, 0xca, 0xf3, 0x24, 0x66, 0xef, 0x97
        ])

        var ciphertext = [UInt8](repeating: 0, count: plaintext.count)
        var ciphertextLen = 0

        let status: CCCryptorStatus = plaintext.withUnsafeBytes { ptBytes in
            key.withUnsafeBytes { keyBytes in
                CCCrypt(
                    CCOperation(kCCEncrypt),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCOptions(kCCOptionECBMode),
                    keyBytes.baseAddress, key.count,
                    nil,
                    ptBytes.baseAddress, plaintext.count,
                    &ciphertext, ciphertext.count,
                    &ciphertextLen
                )
            }
        }

        XCTAssertEqual(status, kCCSuccess, "AES-128-ECB must succeed")
        XCTAssertEqual(ciphertextLen, 16, "Ciphertext must be 16 bytes")
        XCTAssertEqual(Data(ciphertext.prefix(ciphertextLen)), expectedCiphertext,
                       "AES-128-ECB output must match NIST vector")
    }

    // MARK: - HKDF-SHA1 subkey derivation

    func testHKDFSHA1Determinism() throws {
        // Verify that HKDF<Insecure.SHA1> is deterministic for SS-2022 subkey derivation.
        // ikm = 32-byte userPSK, salt = 32-byte requestSalt, info = "ss-subkey"
        let ikm = Data(repeating: 0xAB, count: 32)
        let salt = Data(repeating: 0xCD, count: 32)
        let info = Data("ss-subkey".utf8)

        func derive() -> Data {
            let key = HKDF<Insecure.SHA1>.deriveKey(
                inputKeyMaterial: SymmetricKey(data: ikm),
                salt: salt,
                info: info,
                outputByteCount: 32
            )
            return key.withUnsafeBytes { Data($0) }
        }

        let key1 = derive()
        let key2 = derive()

        XCTAssertEqual(key1.count, 32, "Derived subkey must be 32 bytes")
        XCTAssertEqual(key1, key2, "HKDF must be deterministic")
        XCTAssertNotEqual(key1, ikm, "Derived key must differ from IKM")
    }

    // MARK: - AES-256-GCM AEAD round-trip

    func testAES256GCMRoundTrip() throws {
        // Verify AES-256-GCM seal/open round-trip (used for all SS-2022 chunk encryption)
        let key = SymmetricKey(size: .bits256)

        // 12-byte SS-2022 nonce: 4 zero bytes + 8-byte counter big-endian
        var nonceBytes = Data(count: 12)
        nonceBytes.withUnsafeMutableBytes { buf in
            var counter: UInt64 = 1
            counter = counter.bigEndian
            memcpy(buf.baseAddress! + 4, &counter, 8)
        }
        let nonce = try AES.GCM.Nonce(data: nonceBytes)

        let plaintext = Data("test WireGuard packet payload".utf8)
        let aad = Data("request-salt-aad".utf8)

        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
        let ciphertextPlusTag = Data(sealed.ciphertext) + Data(sealed.tag)

        XCTAssertEqual(ciphertextPlusTag.count, plaintext.count + 16,
                       "Wire ciphertext = plaintext + 16-byte GCM tag")

        // Reconstruct SealedBox from ciphertext+tag (as done in decryptAEAD)
        let ct = ciphertextPlusTag.dropLast(16)
        let tag = ciphertextPlusTag.suffix(16)
        let reconstructed = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ct, tag: tag)
        let decrypted = try AES.GCM.open(reconstructed, using: key, authenticating: aad)

        XCTAssertEqual(decrypted, plaintext, "Decrypted output must match original plaintext")
    }

    // MARK: - BLAKE3 known-vector regression guard
    //
    // These vectors were computed with the Python `blake3` library and independently
    // verified against the BLAKE3 reference implementation.
    // They guard against recurrence of the DERIVE_KEY flag-shift bug (Sprint 3):
    //   DERIVE_KEY_CONTEXT was 1<<4 (wrong), must be 1<<5
    //   DERIVE_KEY_MATERIAL was 1<<5 (wrong), must be 1<<6

    // Inline BLAKE3 — mirrors ShadowsocksTransport.swift exactly.
    // Must stay in sync with the production implementation.
    private let b3IV: [UInt32] = [
        0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
        0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19
    ]
    private let b3SIGMA: [[Int]] = [
        [0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15],
        [2,6,3,10,7,0,4,13,1,11,12,5,9,14,15,8],
        [3,4,10,12,13,2,11,14,6,5,9,0,15,8,7,1],
        [6,11,12,14,8,3,5,15,4,2,7,1,0,13,10,9],
        [10,5,14,9,15,6,2,8,11,3,0,13,4,7,1,12],
        [7,2,9,15,10,4,3,14,5,6,1,8,12,0,11,13],
        [0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15],
        [2,6,3,10,7,0,4,13,1,11,12,5,9,14,15,8]
    ]
    private let b3CHUNK_START: UInt32 = 1 << 0
    private let b3CHUNK_END:   UInt32 = 1 << 1
    private let b3ROOT:        UInt32 = 1 << 3
    private let b3KEYED_HASH:  UInt32 = 1 << 4
    private let b3DERIVE_KEY_CONTEXT:  UInt32 = 1 << 5   // <-- must be 1<<5
    private let b3DERIVE_KEY_MATERIAL: UInt32 = 1 << 6   // <-- must be 1<<6

    private func b3G(_ s: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int,
                     _ x: UInt32, _ y: UInt32) {
        s[a] = s[a] &+ s[b] &+ x
        s[d] = (s[d] ^ s[a]).rotateRight(16)
        s[c] = s[c] &+ s[d]
        s[b] = (s[b] ^ s[c]).rotateRight(12)
        s[a] = s[a] &+ s[b] &+ y
        s[d] = (s[d] ^ s[a]).rotateRight(8)
        s[c] = s[c] &+ s[d]
        s[b] = (s[b] ^ s[c]).rotateRight(7)
    }

    private func b3Compress(_ cv: [UInt32], _ block: [UInt32],
                            _ counter: UInt64, _ blockLen: UInt32,
                            _ flags: UInt32) -> [UInt32] {
        var s: [UInt32] = [
            cv[0], cv[1], cv[2], cv[3],
            cv[4], cv[5], cv[6], cv[7],
            b3IV[0], b3IV[1], b3IV[2], b3IV[3],
            UInt32(counter & 0xFFFFFFFF), UInt32(counter >> 32),
            blockLen, flags
        ]
        for r in 0..<7 {
            let p = b3SIGMA[r]
            b3G(&s, 0, 4,  8, 12, block[p[0]], block[p[1]])
            b3G(&s, 1, 5,  9, 13, block[p[2]], block[p[3]])
            b3G(&s, 2, 6, 10, 14, block[p[4]], block[p[5]])
            b3G(&s, 3, 7, 11, 15, block[p[6]], block[p[7]])
            b3G(&s, 0, 5, 10, 15, block[p[8]], block[p[9]])
            b3G(&s, 1, 6, 11, 12, block[p[10]], block[p[11]])
            b3G(&s, 2, 7,  8, 13, block[p[12]], block[p[13]])
            b3G(&s, 3, 4,  9, 14, block[p[14]], block[p[15]])
        }
        var out = [UInt32](repeating: 0, count: 8)
        for i in 0..<8 { out[i] = s[i] ^ s[i + 8] }
        return out
    }

    private func b3BytesToWords(_ data: Data, paddedTo count: Int) -> [UInt32] {
        var padded = [UInt8](data)
        while padded.count < count { padded.append(0) }
        var words = [UInt32](repeating: 0, count: count / 4)
        for i in 0..<words.count {
            words[i] = UInt32(padded[i*4]) |
                       (UInt32(padded[i*4+1]) << 8) |
                       (UInt32(padded[i*4+2]) << 16) |
                       (UInt32(padded[i*4+3]) << 24)
        }
        return words
    }

    private func b3WordsToBytes(_ words: [UInt32]) -> Data {
        var out = Data(count: words.count * 4)
        for (i, w) in words.enumerated() {
            out[i*4]   = UInt8(w & 0xFF)
            out[i*4+1] = UInt8((w >> 8) & 0xFF)
            out[i*4+2] = UInt8((w >> 16) & 0xFF)
            out[i*4+3] = UInt8((w >> 24) & 0xFF)
        }
        return out
    }

    /// BLAKE3 plain hash (single chunk ≤64 bytes)
    private func b3Hash(_ input: Data) -> Data {
        precondition(input.count <= 64)
        let block = b3BytesToWords(input, paddedTo: 64)
        let flags = b3CHUNK_START | b3CHUNK_END | b3ROOT
        let cv = b3Compress(b3IV, block, 0, UInt32(input.count), flags)
        return b3WordsToBytes(cv)
    }

    /// BLAKE3 derive_key — context string + key material, both ≤64 bytes
    private func b3DeriveKey(context: String, material: Data) -> Data {
        precondition(material.count <= 64)
        let ctxData = Data(context.utf8)
        precondition(ctxData.count <= 64)
        // Step 1: hash context string with DERIVE_KEY_CONTEXT flags
        let ctxBlock = b3BytesToWords(ctxData, paddedTo: 64)
        let ctxFlags = b3CHUNK_START | b3CHUNK_END | b3ROOT | b3DERIVE_KEY_CONTEXT
        let ctxKey = b3Compress(b3IV, ctxBlock, 0, UInt32(ctxData.count), ctxFlags)
        // Step 2: compress key material with DERIVE_KEY_MATERIAL flags, using ctxKey as CV
        let matBlock = b3BytesToWords(material, paddedTo: 64)
        let matFlags = b3CHUNK_START | b3CHUNK_END | b3ROOT | b3DERIVE_KEY_MATERIAL
        let out = b3Compress(ctxKey, matBlock, 0, UInt32(material.count), matFlags)
        return b3WordsToBytes(out)
    }

    func testBLAKE3EmptyHash() {
        // BLAKE3() = af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262
        let result = b3Hash(Data())
        XCTAssertEqual(result.map { String(format: "%02x", $0) }.joined(),
                       "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262",
                       "BLAKE3 empty hash must match reference")
    }

    func testBLAKE3SingleZeroByte() {
        // BLAKE3(0x00) = 2d3adedff11b61f14c886e35afa036736dcd87a74d27b5c1510225d0f592e213
        let result = b3Hash(Data([0x00]))
        XCTAssertEqual(result.map { String(format: "%02x", $0) }.joined(),
                       "2d3adedff11b61f14c886e35afa036736dcd87a74d27b5c1510225d0f592e213",
                       "BLAKE3(0x00) must match reference")
    }

    func testBLAKE3DeriveKeyEIHVector() throws {
        // These are the actual PSK values used in the Sprint 3 integration test (vpn-ewr-01)
        // serverPSK = base64("P5xVorV89PY9SVbyjBey4h3VSLUjT8Bugu36ihT8A0Q=")
        // userPSK   = base64("lEl+fVJfnax/Or9krKIhlhxjVM3Esoio3EvWb/sdDKc=")
        // fixedSalt = 32 x 0x55 (test vector, not a real session salt)
        //
        // Expected: BLAKE3.derive_key("shadowsocks 2022 identity subkey", serverPSK||fixedSalt)
        //           = faeb4244a8989631c0531edc987ef48a53c4a02b8c2ec4b84dfe46056a8eaaa7
        //
        // This test WILL FAIL if DERIVE_KEY_CONTEXT reverts to 1<<4.
        let serverPSKB64 = "P5xVorV89PY9SVbyjBey4h3VSLUjT8Bugu36ihT8A0Q="
        let serverPSK = Data(base64Encoded: serverPSKB64)!
        let fixedSalt = Data(repeating: 0x55, count: 32)
        var material = serverPSK
        material.append(fixedSalt)  // 64 bytes total

        let result = b3DeriveKey(context: "shadowsocks 2022 identity subkey", material: material)
        XCTAssertEqual(result.map { String(format: "%02x", $0) }.joined(),
                       "faeb4244a8989631c0531edc987ef48a53c4a02b8c2ec4b84dfe46056a8eaaa7",
                       "BLAKE3 EIH subkey derivation must match reference vector; " +
                       "failure = DERIVE_KEY_CONTEXT flag is wrong (must be 1<<5, not 1<<4)")
    }

    func testBLAKE3UserPSKHash() throws {
        // BLAKE3.hash(userPSK) used in EIH block (first 16 bytes AES-128-ECB encrypted with DK[0..16])
        // userPSK = base64("lEl+fVJfnax/Or9krKIhlhxjVM3Esoio3EvWb/sdDKc=")
        // Expected = f53cbcb49c40489c38b6ed050a424a927655bac4f17a07ff78db82fd80982ab5
        let userPSK = Data(base64Encoded: "lEl+fVJfnax/Or9krKIhlhxjVM3Esoio3EvWb/sdDKc=")!
        let result = b3Hash(userPSK)
        XCTAssertEqual(result.map { String(format: "%02x", $0) }.joined(),
                       "f53cbcb49c40489c38b6ed050a424a927655bac4f17a07ff78db82fd80982ab5",
                       "BLAKE3 userPSK hash must match reference vector")
    }
    // MARK: - WebSocket framing (Sprint 4)
    // These tests validate the WS handshake accept-key derivation and BINARY frame
    // wrapping/parsing that ShadowsocksTransport uses to tunnel SS-2022 through v2ray-plugin.
    // All tests are self-contained; no network access required.

    // Inline wsWrapBinary for test isolation (mirrors ShadowsocksTransport.wsWrapBinary)
    private func wsWrapBinary(_ payload: Data) -> Data {
        var frame = Data()
        frame.append(0x82) // FIN=1, opcode=2 (binary)
        let len = payload.count
        if len <= 125 {
            frame.append(UInt8(len))
        } else if len <= 65535 {
            frame.append(126)
            frame.append(UInt8((len >> 8) & 0xFF))
            frame.append(UInt8(len & 0xFF))
        } else {
            frame.append(127)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((len >> shift) & 0xFF))
            }
        }
        frame.append(contentsOf: payload)
        return frame
    }

    // Inline wsParseFrame for test isolation
    private func wsParseFrame(_ data: Data) throws -> Data {
        guard data.count >= 2 else { throw NSError(domain: "WSTest", code: 1) }
        let lenByte = data[1] & 0x7F
        let headerEnd: Int
        let payloadLen: Int
        if lenByte <= 125 {
            payloadLen = Int(lenByte)
            headerEnd = 2
        } else if lenByte == 126 {
            guard data.count >= 4 else { throw NSError(domain: "WSTest", code: 2) }
            payloadLen = (Int(data[2]) << 8) | Int(data[3])
            headerEnd = 4
        } else {
            guard data.count >= 10 else { throw NSError(domain: "WSTest", code: 3) }
            payloadLen = (Int(data[2]) << 56) | (Int(data[3]) << 48) |
                         (Int(data[4]) << 40) | (Int(data[5]) << 32) |
                         (Int(data[6]) << 24) | (Int(data[7]) << 16) |
                         (Int(data[8]) << 8)  | Int(data[9])
            headerEnd = 10
        }
        return data[headerEnd ..< headerEnd + payloadLen]
    }

    func testWSAcceptKeyDerivation() throws {
        // RFC 6455 §4.2.2: Accept = base64(SHA1(Key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
        // Known vector from RFC 6455 §1.3 example:
        // Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==
        // Expected Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=
        let wsKey = "dGhlIHNhbXBsZSBub25jZQ=="
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let combined = wsKey + magic
        let sha1 = Insecure.SHA1.hash(data: Data(combined.utf8))
        let accept = Data(sha1).base64EncodedString()
        XCTAssertEqual(accept, "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
                       "WS Accept key derivation must match RFC 6455 §1.3 known vector")
    }

    func testWSBinaryFrameShortPayload() {
        // Payload <= 125 bytes: header is 2 bytes (0x82, len)
        let payload = Data(repeating: 0xAB, count: 32)
        let frame = wsWrapBinary(payload)
        XCTAssertEqual(frame.count, 34, "Short payload frame must be 2-byte header + 32-byte payload")
        XCTAssertEqual(frame[0], 0x82, "First byte must be FIN=1 + opcode=2 (binary)")
        XCTAssertEqual(frame[1], 32, "Length byte must equal payload length for short frames")
        XCTAssertEqual(frame[2...], payload, "Payload bytes must follow header unchanged")
    }

    func testWSBinaryFrameExtended16BitPayload() {
        // Payload 126..65535: header is 4 bytes (0x82, 126, len_hi, len_lo)
        let payload = Data(repeating: 0xCD, count: 200)
        let frame = wsWrapBinary(payload)
        XCTAssertEqual(frame.count, 204, "Extended-16 frame must be 4-byte header + 200-byte payload")
        XCTAssertEqual(frame[0], 0x82, "First byte must be FIN=1 + opcode=2")
        XCTAssertEqual(frame[1], 126, "Length indicator must be 126 for 16-bit extended length")
        let encodedLen = (Int(frame[2]) << 8) | Int(frame[3])
        XCTAssertEqual(encodedLen, 200, "Encoded 16-bit length must equal payload byte count")
        XCTAssertEqual(frame[4...], payload, "Payload bytes must follow extended header unchanged")
    }

    func testWSBinaryFrameRoundTrip() throws {
        // Encode then decode; payload must be recovered intact
        let original = Data((0..<64).map { UInt8($0) })
        let frame = wsWrapBinary(original)
        let recovered = try wsParseFrame(frame)
        XCTAssertEqual(recovered, original,
                       "Parsed payload must exactly equal original after WS BINARY frame round-trip")
    }

    func testWSBinaryFrameRoundTripExtended() throws {
        // Round-trip for a 300-byte payload (forces 16-bit extended length path)
        let original = Data(repeating: 0xFF, count: 300)
        let frame = wsWrapBinary(original)
        let recovered = try wsParseFrame(frame)
        XCTAssertEqual(recovered, original,
                       "Parsed payload must exactly equal original for extended-length WS frame")
    }

}