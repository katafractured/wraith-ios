// ShadowsocksTransport.swift
// WireGuardTunnel
//
// Pure-Swift SS-2022 AEAD client transport.
// Cipher: 2022-blake3-aes-256-gcm
// Wire: salt(32) + EIH(16) + AEAD(fixedHeader, aad=salt) + AEAD(addrData, aad=Data()) + AEAD chunks
// Subkey: HKDF-SHA1(ikm=userPSK, salt=requestSalt, info="ss-subkey")
// EIH key: BLAKE3.deriveKey("shadowsocks 2022 identity subkey", serverPSK||requestSalt)[0..32]
// EIH plaintext: BLAKE3.hash(userPSK)[0..16]
// No Go toolchain required.

import Foundation
@preconcurrency import Network
import CryptoKit
import CommonCrypto
import NetworkExtension

// MARK: - Configuration

struct SSTunnelConfig {
    let server: String          // hostname, e.g. "vpn-iad-01.vpn.katafract.com"
    let port: UInt16            // TLS port, e.g. 8443
    let password: String        // "SERVER_PSK_b64:USER_PSK_b64"
    let serverNodeIP: String    // WG server public IP, e.g. "87.99.128.159"
}

// MARK: - Errors

enum ShadowsocksError: LocalizedError {
    case invalidPassword
    case invalidBase64
    case connectionFailed(String)
    case encryptionFailed(String)
    case decryptionFailed(String)
    case invalidState(String)
    case ioError(String)

    var errorDescription: String? {
        switch self {
        case .invalidPassword:
            return "Invalid Shadowsocks password format (expected SERVER_PSK:USER_PSK)"
        case .invalidBase64:
            return "Invalid base64 encoding in Shadowsocks password"
        case .connectionFailed(let msg):
            return "Shadowsocks connection failed: \(msg)"
        case .encryptionFailed(let msg):
            return "Shadowsocks encryption failed: \(msg)"
        case .decryptionFailed(let msg):
            return "Shadowsocks decryption failed: \(msg)"
        case .invalidState(let msg):
            return "Shadowsocks invalid state: \(msg)"
        case .ioError(let msg):
            return "Shadowsocks I/O error: \(msg)"
        }
    }
}

// MARK: - Shadowsocks Transport

actor ShadowsocksTransport {
    private var connection: NWConnection?
    private var running = false
    private var sendNonce: UInt64 = 2   // nonces 0+1 consumed by fixedHeader + addrData
    private var recvNonce: UInt64 = 0   // server responses start at 0

    private var subkey: Data?
    private var serverPSK: Data?
    private var userPSK: Data?
    private var serverFQDN: String = ""  // stored for WS Host header

    nonisolated private let log = { (msg: String) in
        NSLog("[ShadowsocksTransport] %@", msg)
    }

    // MARK: - Lifecycle

    func start(config: SSTunnelConfig, packetFlow: NEPacketTunnelFlow) async throws {
        log("Starting to \(config.server):\(config.port)")
        self.serverFQDN = config.server

        // Parse "SERVER_PSK_b64:USER_PSK_b64"
        let (serverPSKData, userPSKData) = try parsePassword(config.password)
        self.serverPSK = serverPSKData
        self.userPSK = userPSKData

        // 32-byte random request salt
        var requestSalt = Data(count: 32)
        let saltResult = requestSalt.withUnsafeMutableBytes { (buf: UnsafeMutableRawBufferPointer) -> OSStatus in
            SecRandomCopyBytes(kSecRandomDefault, 32, buf.baseAddress!)
        }
        guard saltResult == errSecSuccess else {
            throw ShadowsocksError.encryptionFailed("SecRandomCopyBytes failed")
        }

        // Derive session subkey: HKDF-SHA1(ikm=userPSK, salt=requestSalt)
        let derivedSubkey = try deriveSubkey(ikm: userPSKData, salt: requestSalt)
        self.subkey = derivedSubkey

        // Build 16-byte EIH block for multi-user ssservice
        let eihBlock = try buildEIH(
            serverPSK: serverPSKData,
            userPSK: userPSKData,
            requestSalt: requestSalt
        )

        // Build and encrypt the fixed header (nonce=0, aad=requestSalt)
        // Fixed header plaintext: type(1) + timestamp(8) + length(2) = 11 bytes
        // where length is the size of the address data that follows (9 bytes)
        let fixedHeaderPlaintext = buildFixedHeader(
            timestamp: UInt64(Date().timeIntervalSince1970)
        )
        let encryptedHeader = try encryptAEAD(
            key: derivedSubkey,
            nonce: makeNonce(counter: 0),
            plaintext: fixedHeaderPlaintext,
            aad: requestSalt
        )

        // Build and encrypt the address data (nonce=1, aad=Data())
        // Address data plaintext: ATYP(1) + IPv4(4) + port(2) + padding_len(2) = 9 bytes
        let addrDataPlaintext = try buildAddressData(serverNodeIP: config.serverNodeIP)
        let encryptedAddrData = try encryptAEAD(
            key: derivedSubkey,
            nonce: makeNonce(counter: 1),
            plaintext: addrDataPlaintext,
            aad: Data()
        )
        self.sendNonce = 2

        // Open TLS connection (v2ray-plugin terminates TLS on the server side)
        let host = NWEndpoint.Host(config.server)
        guard let port = NWEndpoint.Port(rawValue: config.port) else {
            throw ShadowsocksError.connectionFailed("Invalid port: \(config.port)")
        }
        let tlsParams = NWParameters(tls: NWProtocolTLS.Options())
        // Note: NWParameters.preferNoProxy is not a public API on iOS.
        // NEPacketTunnelProvider runs outside the system proxy stack automatically.
        let conn = NWConnection(host: host, port: port, using: tlsParams)
        self.connection = conn

        try await waitForConnectionReady(connection: conn)
        log("TLS connected")

        // Perform WebSocket Upgrade handshake (v2ray-plugin requires WS before SS bytes)
        try await wsHandshake(connection: conn, host: config.server)
        log("WebSocket upgrade complete")

        // Wire format: salt(32) + EIH(16) + AEAD(fixedHeader) + AEAD(addrData)
        // salt must precede EIH — server reads salt first to derive the EIH decryption key
        let wirePrefix = requestSalt + eihBlock + encryptedHeader + encryptedAddrData
        let wrappedPrefix = wsWrapBinary(wirePrefix)
        try await sendData(wrappedPrefix, connection: conn)
        log("Sent wire prefix (\(wirePrefix.count) bytes, \(wrappedPrefix.count) on wire)")

        // NB: do NOT set running=true / spawn loops yet. The PacketTunnelProvider
        // calls verifyServerAccepted() between start() and engaging the loops so
        // we don't claim Stealth is active when the server silently rejected us.
        self.running = true
    }

    /// Spawn the bidirectional packet pumps. Caller must invoke this only after
    /// verifyServerAccepted() has returned true; otherwise we'd silently feed
    /// real WG packets into a dead/rejected SS connection.
    func startPumps(packetFlow: NEPacketTunnelFlow) {
        guard let connection, running else {
            log("startPumps called but transport not running")
            return
        }
        Task { await self.readLoop(connection: connection, packetFlow: packetFlow) }
        Task { await self.writeLoop(connection: connection, packetFlow: packetFlow) }
    }

    func stop() async {
        log("Stopping")
        running = false
        connection?.cancel()
        connection = nil
    }

    /// Verify the SS-2022 connection was actually accepted by the server.
    ///
    /// The server (shadowsocks-rust ssservice) is a SOCKS5-style relay — it
    /// only emits bytes back to us when the target (127.0.0.1:51820 = WG
    /// server) replies. So a positive-data probe doesn't work when no
    /// traffic is flowing yet.
    ///
    /// We instead poll `connection.state` for `timeoutSeconds`. A silent
    /// server reject (bad PSK, EIH mismatch, WS handshake rejected after
    /// the fact) typically tears down the TCP conn within ~50-200ms after
    /// the bad SS-2022 prefix arrives. So if state stays `.ready` for
    /// 2-3 seconds, auth was almost certainly accepted.
    ///
    /// Returns `true` if the connection stays `.ready` for the full window.
    func verifyServerAccepted(timeoutSeconds: Double) async -> Bool {
        guard let connection else {
            log("verify: no connection")
            return false
        }
        guard running else {
            log("verify: not running")
            return false
        }

        let pollIntervalNanos: UInt64 = 100_000_000  // 100ms
        let totalIterations = max(1, Int(timeoutSeconds * 10))

        for i in 0..<totalIterations {
            switch connection.state {
            case .failed(let err):
                log("verify: state=failed at i=\(i) — \(err.localizedDescription)")
                return false
            case .cancelled:
                log("verify: state=cancelled at i=\(i)")
                return false
            case .ready:
                break  // continue polling
            default:
                // .setup, .preparing, .waiting — should already be past these.
                log("verify: state=\(String(describing: connection.state)) at i=\(i)")
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanos)
        }

        log("verify: connection stayed .ready for \(timeoutSeconds)s — accepting")
        return true
    }

    // MARK: - Read Loop (Server → WireGuard)

    private func readLoop(connection: NWConnection, packetFlow: NEPacketTunnelFlow) async {
        while running {
            do {
                guard let subkey = self.subkey else {
                    throw ShadowsocksError.invalidState("Subkey not set")
                }

                // Receive one WS BINARY frame containing one full SS-2022 chunk
                // Frame contains: encLen(18 bytes) + encPayload(payloadLen + 16 bytes)
                let wsFrame = try await wsReceiveFrame(from: connection)
                guard wsFrame.count >= 18 else {
                    throw ShadowsocksError.decryptionFailed("WS frame too short for SS header: \(wsFrame.count)")
                }

                // Parse encLen from first 18 bytes of frame
                let encLen = wsFrame.prefix(18)
                let lenData = try decryptAEAD(
                    key: subkey,
                    nonce: makeNonce(counter: recvNonce),
                    ciphertext: Data(encLen),
                    aad: Data()
                )
                guard lenData.count == 2 else {
                    throw ShadowsocksError.decryptionFailed("Length block wrong size: \(lenData.count)")
                }
                let payloadLen = Int(lenData.withUnsafeBytes { $0.load(as: UInt16.self).bigEndian })
                recvNonce += 1

                // Parse encPayload from remaining bytes of frame
                let expectedFrameLen = 18 + payloadLen + 16
                guard wsFrame.count == expectedFrameLen else {
                    throw ShadowsocksError.decryptionFailed("WS frame size mismatch: got \(wsFrame.count), expected \(expectedFrameLen)")
                }
                let encPayload = wsFrame.dropFirst(18)
                let payload = try decryptAEAD(
                    key: subkey,
                    nonce: makeNonce(counter: recvNonce),
                    ciphertext: Data(encPayload),
                    aad: Data()
                )
                recvNonce += 1

                packetFlow.writePackets([payload], withProtocols: [AF_INET as NSNumber])
                log("→ WG \(payload.count) bytes")

            } catch {
                log("Read loop error: \(error.localizedDescription)")
                running = false
            }
        }
    }

    // MARK: - Write Loop (WireGuard → Server)

    private func writeLoop(connection: NWConnection, packetFlow: NEPacketTunnelFlow) async {
        while running {
            do {
                guard let subkey = self.subkey else {
                    throw ShadowsocksError.invalidState("Subkey not set")
                }

                // readPacketObjects is callback-based; bridge to async
                let packets: [NEPacket] = await withCheckedContinuation { continuation in
                    packetFlow.readPacketObjects { pkts in
                        continuation.resume(returning: pkts ?? [])
                    }
                }

                guard !packets.isEmpty else {
                    try await Task.sleep(nanoseconds: 10_000_000)  // 10 ms
                    continue
                }

                for packet in packets {
                    let payload = packet.data

                    // Encrypt length (2 bytes big-endian uint16)
                    var lenBE = UInt16(payload.count).bigEndian
                    let lenPlaintext = Data(bytes: &lenBE, count: 2)
                    let encLen = try encryptAEAD(
                        key: subkey,
                        nonce: makeNonce(counter: sendNonce),
                        plaintext: lenPlaintext,
                        aad: Data()
                    )
                    sendNonce += 1

                    // Encrypt payload
                    let encPayload = try encryptAEAD(
                        key: subkey,
                        nonce: makeNonce(counter: sendNonce),
                        plaintext: payload,
                        aad: Data()
                    )
                    sendNonce += 1

                    let chunk = encLen + encPayload
                    let wsChunk = wsWrapBinary(chunk)
                    try await sendData(wsChunk, connection: connection)
                    log("WG → \(payload.count) bytes (\(wsChunk.count) on wire)")
                }

            } catch {
                log("Write loop error: \(error.localizedDescription)")
                running = false
            }
        }
    }

    // MARK: - WebSocket Transport Layer

    /// Perform RFC 6455 WebSocket Upgrade handshake over an already-open TLS connection.
    /// v2ray-plugin in TLS+websocket mode requires this before any SS-2022 bytes.
    private func wsHandshake(connection: NWConnection, host: String) async throws {
        // Generate random 16-byte key for Sec-WebSocket-Key
        var keyBytes = Data(count: 16)
        _ = keyBytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let wsKey = keyBytes.base64EncodedString()

        // Compute expected Sec-WebSocket-Accept
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let acceptInput = Data((wsKey + magic).utf8)
        var digestBytes = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        acceptInput.withUnsafeBytes {
            _ = CC_SHA1($0.baseAddress, CC_LONG($0.count), &digestBytes)
        }
        let expectedAccept = Data(digestBytes).base64EncodedString()

        // Build HTTP/1.1 Upgrade request
        let request = [
            "GET / HTTP/1.1",
            "Host: \(host)",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Key: \(wsKey)",
            "Sec-WebSocket-Version: 13",
            "",
            ""
        ].joined(separator: "\r\n")

        try await sendData(Data(request.utf8), connection: connection)

        // Read HTTP response line-by-line until \r\n\r\n. Race against a
        // 5-second hard timeout so a misconfigured server (e.g., v2ray-plugin
        // with no `mode=websocket` falling back to raw TLS passthrough that
        // forwards our HTTP-shaped bytes to ssservice as garbage SS) doesn't
        // hang the extension forever.
        let maxResponseBytes = 4096
        let responseData: Data = try await withThrowingTaskGroup(of: Data.self, returning: Data.self) { group in
            group.addTask { [self] in
                var buf = Data()
                while buf.count < maxResponseBytes {
                    let chunk = try await self.receiveExactly(1, from: connection)
                    buf.append(contentsOf: chunk)
                    if buf.suffix(4) == Data([0x0D, 0x0A, 0x0D, 0x0A]) {
                        return buf
                    }
                }
                throw ShadowsocksError.connectionFailed("WS upgrade response exceeded \(maxResponseBytes) bytes without \\r\\n\\r\\n terminator")
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 5_000_000_000)  // 5s
                throw ShadowsocksError.connectionFailed("WS upgrade timed out (5s) — server may not be configured for mode=websocket")
            }
            let result = try await group.next() ?? Data()
            group.cancelAll()
            return result
        }
        var gotAccept = false
        var got101 = false

        let responseStr = String(data: responseData, encoding: .utf8) ?? ""
        let lines = responseStr.components(separatedBy: "\r\n")

        for (i, line) in lines.enumerated() {
            if i == 0 {
                got101 = line.contains("101")
            } else {
                let lower = line.lowercased()
                if lower.hasPrefix("sec-websocket-accept:") {
                    let parts = line.split(separator: ":", maxSplits: 1)
                    if parts.count == 2 {
                        let serverAccept = String(parts[1]).trimmingCharacters(in: .whitespaces)
                        gotAccept = (serverAccept == expectedAccept)
                    }
                }
            }
        }

        guard got101 else {
            throw ShadowsocksError.connectionFailed("WebSocket upgrade failed: no 101 response. Got: \(lines.first ?? "(empty)")")
        }
        guard gotAccept else {
            throw ShadowsocksError.connectionFailed("WebSocket upgrade failed: Sec-WebSocket-Accept mismatch. Expected: \(expectedAccept)")
        }
    }

    /// Wrap data in a WebSocket BINARY frame (RFC 6455, client→server, unmasked).
    /// v2ray-plugin server accepts unmasked frames (standard for server-to-server).
    /// Frame format: 0x82 (FIN+binary) | length encoding | payload
    nonisolated func wsWrapBinary(_ payload: Data) -> Data {
        var frame = Data()
        frame.append(0x82)  // FIN=1, opcode=2 (binary)
        let len = payload.count
        if len <= 125 {
            frame.append(UInt8(len))
        } else if len <= 65535 {
            frame.append(126)
            var lenBE = UInt16(len).bigEndian
            frame.append(Data(bytes: &lenBE, count: 2))
        } else {
            frame.append(127)
            var lenBE = UInt64(len).bigEndian
            frame.append(Data(bytes: &lenBE, count: 8))
        }
        frame.append(payload)
        return frame
    }

    /// Receive one complete WebSocket frame and return its payload.
    /// Handles 7-bit, 16-bit, and 64-bit payload lengths. Strips opcode/mask header.
    private func wsReceiveFrame(from connection: NWConnection) async throws -> Data {
        // Read first 2 header bytes
        let header = try await receiveExactly(2, from: connection)
        // header[0]: FIN + opcode (we expect 0x82 = binary, but accept any opcode)
        let lenByte = header[1] & 0x7F
        let isMasked = (header[1] & 0x80) != 0

        // Determine payload length
        let payloadLen: Int
        if lenByte <= 125 {
            payloadLen = Int(lenByte)
        } else if lenByte == 126 {
            let extLen = try await receiveExactly(2, from: connection)
            payloadLen = Int(extLen.withUnsafeBytes { $0.load(as: UInt16.self).bigEndian })
        } else {  // 127
            let extLen = try await receiveExactly(8, from: connection)
            payloadLen = Int(extLen.withUnsafeBytes { $0.load(as: UInt64.self).bigEndian })
        }

        // Read mask key if present (server→client frames are typically unmasked)
        var maskKey = Data(count: 4)
        if isMasked {
            maskKey = try await receiveExactly(4, from: connection)
        }

        // Read payload
        var payload = try await receiveExactly(payloadLen, from: connection)

        // Unmask if necessary
        if isMasked {
            payload.withUnsafeMutableBytes { (buf: UnsafeMutableRawBufferPointer) in
                for i in 0..<payloadLen {
                    buf[i] ^= maskKey[i % 4]
                }
            }
        }

        return payload
    }

    // MARK: - Cryptography

    private func parsePassword(_ password: String) throws -> (serverPSK: Data, userPSK: Data) {
        let parts = password.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw ShadowsocksError.invalidPassword }

        guard let serverPSKData = Data(base64Encoded: String(parts[0])),
              serverPSKData.count == 32 else {
            throw ShadowsocksError.invalidBase64
        }
        guard let userPSKData = Data(base64Encoded: String(parts[1])),
              userPSKData.count == 32 else {
            throw ShadowsocksError.invalidBase64
        }
        return (serverPSKData, userPSKData)
    }

    /// HKDF-SHA1(ikm: userPSK, salt: requestSalt, info: "ss-subkey", outputByteCount: 32)
    private func deriveSubkey(ikm: Data, salt: Data) throws -> Data {
        let info = Data("ss-subkey".utf8)
        let derivedKey = HKDF<Insecure.SHA1>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: salt,
            info: info,
            outputByteCount: 32
        )
        return derivedKey.withUnsafeBytes { Data($0) }
    }

    /// EIH = AES-256-ECB(
    ///   key:       blake3DeriveKey("shadowsocks 2022 identity subkey", serverPSK||requestSalt)[0..32],
    ///   plaintext: blake3Hash(userPSK)[0..16]
    /// )
    private func buildEIH(serverPSK: Data, userPSK: Data, requestSalt: Data) throws -> Data {
        // Key material for derive_key: serverPSK || requestSalt
        var keyMaterial = Data()
        keyMaterial.append(serverPSK)
        keyMaterial.append(requestSalt)
        // Derive 32-byte AES-256 key using BLAKE3 key-derivation mode
        let eihKeyFull = blake3DeriveKey(context: "shadowsocks 2022 identity subkey", keyMaterial: keyMaterial)
        // EIH plaintext is the first 16 bytes of blake3Hash(userPSK)
        let userPSKHash = blake3Hash(userPSK)
        let plaintext = userPSKHash.prefix(16)
        return try aesECBEncrypt(key: Data(eihKeyFull), plaintext: Data(plaintext))
    }

    /// SS-2022 TCP fixed header plaintext: type(1) + timestamp(8) + length(2) = 11 bytes
    /// where length is the byte count of the address data chunk (9 bytes)
    private func buildFixedHeader(timestamp: UInt64) -> Data {
        var header = Data()
        header.append(0x00)                             // type: TCP request
        var ts = timestamp.bigEndian
        header.append(Data(bytes: &ts, count: 8))       // 8-byte timestamp
        var addrLen = UInt16(9).bigEndian               // address data is 9 bytes
        header.append(Data(bytes: &addrLen, count: 2))  // 2-byte length field
        return header  // 11 bytes total
    }

    /// SS-2022 TCP address data plaintext: ATYP(1) + IPv4(4) + port(2) + padding_len(2) = 9 bytes
    private func buildAddressData(serverNodeIP: String) throws -> Data {
        var addr = Data()
        addr.append(0x01)  // ATYP: IPv4
        let octets = serverNodeIP.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else {
            throw ShadowsocksError.encryptionFailed("Invalid IPv4: \(serverNodeIP)")
        }
        addr.append(contentsOf: octets)                     // 4 bytes IPv4
        var wgPort = UInt16(51820).bigEndian
        addr.append(Data(bytes: &wgPort, count: 2))         // 2-byte port
        addr.append(contentsOf: [0x00, 0x00])               // 2-byte padding length = 0
        return addr  // 9 bytes total
    }

    private func encryptAEAD(key: Data, nonce: Data, plaintext: Data, aad: Data) throws -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let nonceObj = try AES.GCM.Nonce(data: nonce)
        let sealedBox = try AES.GCM.seal(plaintext, using: symmetricKey, nonce: nonceObj, authenticating: aad)
        return Data(sealedBox.ciphertext) + Data(sealedBox.tag)
    }

    private func decryptAEAD(key: Data, nonce: Data, ciphertext: Data, aad: Data) throws -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let nonceObj = try AES.GCM.Nonce(data: nonce)
        guard ciphertext.count >= 16 else {
            throw ShadowsocksError.decryptionFailed("Ciphertext too short: \(ciphertext.count)")
        }
        let ct = ciphertext.dropLast(16)
        let tag = ciphertext.suffix(16)
        let sealedBox = try AES.GCM.SealedBox(nonce: nonceObj, ciphertext: ct, tag: tag)
        return try AES.GCM.open(sealedBox, using: symmetricKey, authenticating: aad)
    }

    private func aesECBEncrypt(key: Data, plaintext: Data) throws -> Data {
        var ciphertext = [UInt8](repeating: 0, count: plaintext.count)
        var numBytesEncrypted = 0
        let status: CCCryptorStatus = key.withUnsafeBytes { keyBytes in
            plaintext.withUnsafeBytes { ptBytes in
                CCCrypt(
                    CCOperation(kCCEncrypt),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCOptions(kCCOptionECBMode),
                    keyBytes.baseAddress, key.count,
                    nil,
                    ptBytes.baseAddress, plaintext.count,
                    &ciphertext, ciphertext.count,
                    &numBytesEncrypted
                )
            }
        }
        guard status == kCCSuccess else {
            throw ShadowsocksError.encryptionFailed("AES-ECB failed: \(status)")
        }
        return Data(ciphertext.prefix(numBytesEncrypted))
    }

    // MARK: - Nonce

    /// SS-2022 nonce: 4 zero bytes + 8-byte counter big-endian = 12 bytes
    private func makeNonce(counter: UInt64) -> Data {
        var nonce = Data(count: 12)
        nonce.withUnsafeMutableBytes { (buf: UnsafeMutableRawBufferPointer) in
            var c = counter.bigEndian
            memcpy(buf.baseAddress! + 4, &c, 8)
        }
        return nonce
    }

    // MARK: - Network I/O

    private func waitForConnectionReady(connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false
            connection.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    continuation.resume()
                case .failed(let error):
                    resumed = true
                    continuation.resume(throwing: ShadowsocksError.connectionFailed(error.localizedDescription))
                case .cancelled:
                    resumed = true
                    continuation.resume(throwing: ShadowsocksError.connectionFailed("Cancelled"))
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                if !resumed {
                    resumed = true
                    continuation.resume(throwing: ShadowsocksError.connectionFailed("Timeout"))
                }
            }
        }
    }

    private func sendData(_ data: Data, connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: ShadowsocksError.ioError(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func receiveExactly(_ count: Int, from connection: NWConnection) async throws -> Data {
        var buffer = Data()
        while buffer.count < count {
            let remaining = count - buffer.count
            // Use minimumIncompleteLength: 1 so the callback fires only when
            // bytes ARE available (or the connection terminates). Avoids the
            // 1ms busy-poll the previous implementation degenerated into when
            // an empty-data callback fired.
            let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                var resumed = false
                connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, isComplete, error in
                    guard !resumed else { return }
                    resumed = true
                    if let error = error {
                        continuation.resume(throwing: ShadowsocksError.ioError(error.localizedDescription))
                    } else if let data, !data.isEmpty {
                        continuation.resume(returning: data)
                    } else if isComplete {
                        continuation.resume(throwing: ShadowsocksError.ioError("Connection closed"))
                    } else {
                        // Should not happen with minimumIncompleteLength: 1 —
                        // but if it does, surface as an error rather than
                        // burn CPU spin-looping.
                        continuation.resume(throwing: ShadowsocksError.ioError("Empty receive callback"))
                    }
                }
            }
            buffer.append(chunk)
        }
        return buffer
    }
}

// MARK: - Inline BLAKE3
//
// Implements two BLAKE3 operations required by SS-2022:
//   blake3Hash(_:)      — plain hash (CHUNK_START | CHUNK_END | ROOT flags)
//   blake3DeriveKey(_:) — key derivation mode (DERIVE_KEY_CONTEXT then DERIVE_KEY_MATERIAL)
//
// Both handle inputs up to 64 bytes (single chunk).
// Reference: https://github.com/BLAKE3-team/BLAKE3-specs/blob/master/blake3.pdf

private let blake3IV: [UInt32] = [
    0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
    0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19
]

private let blake3MsgPermutation: [Int] = [2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8]

private let blake3CHUNK_START:        UInt32 = 1 << 0
private let blake3CHUNK_END:          UInt32 = 1 << 1
private let blake3ROOT:               UInt32 = 1 << 3
private let blake3DERIVE_KEY_CONTEXT: UInt32 = 1 << 5
private let blake3DERIVE_KEY_MATERIAL: UInt32 = 1 << 6

private func blake3G(
    _ state: inout [UInt32], a: Int, b: Int, c: Int, d: Int,
    mx: UInt32, my: UInt32
) {
    state[a] = state[a] &+ state[b] &+ mx
    state[d] = (state[d] ^ state[a]).rotateRight(16)
    state[c] = state[c] &+ state[d]
    state[b] = (state[b] ^ state[c]).rotateRight(12)
    state[a] = state[a] &+ state[b] &+ my
    state[d] = (state[d] ^ state[a]).rotateRight(8)
    state[c] = state[c] &+ state[d]
    state[b] = (state[b] ^ state[c]).rotateRight(7)
}

private func blake3Round(_ state: inout [UInt32], m: [UInt32]) {
    // column step
    blake3G(&state, a: 0, b: 4, c: 8,  d: 12, mx: m[0],  my: m[1])
    blake3G(&state, a: 1, b: 5, c: 9,  d: 13, mx: m[2],  my: m[3])
    blake3G(&state, a: 2, b: 6, c: 10, d: 14, mx: m[4],  my: m[5])
    blake3G(&state, a: 3, b: 7, c: 11, d: 15, mx: m[6],  my: m[7])
    // diagonal step
    blake3G(&state, a: 0, b: 5, c: 10, d: 15, mx: m[8],  my: m[9])
    blake3G(&state, a: 1, b: 6, c: 11, d: 12, mx: m[10], my: m[11])
    blake3G(&state, a: 2, b: 7, c: 8,  d: 13, mx: m[12], my: m[13])
    blake3G(&state, a: 3, b: 4, c: 9,  d: 14, mx: m[14], my: m[15])
}

private func blake3Compress(
    cv: [UInt32], block: [UInt32], blockLen: UInt32,
    counter: UInt64, flags: UInt32
) -> [UInt32] {
    var state: [UInt32] = [
        cv[0], cv[1], cv[2], cv[3],
        cv[4], cv[5], cv[6], cv[7],
        blake3IV[0], blake3IV[1], blake3IV[2], blake3IV[3],
        UInt32(counter & 0xFFFFFFFF), UInt32(counter >> 32),
        blockLen, flags
    ]

    var m = block
    for _ in 0..<7 {
        blake3Round(&state, m: m)
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

/// Pack a byte slice (up to 64 bytes) into 16 little-endian uint32 words.
private func blake3BlockWords(from input: Data, padToCount: Int = 64) -> [UInt32] {
    var padded = [UInt8](input) + [UInt8](repeating: 0, count: max(0, padToCount - input.count))
    padded = Array(padded.prefix(padToCount))
    var block = [UInt32](repeating: 0, count: 16)
    for i in 0..<16 {
        let off = i * 4
        block[i] = UInt32(padded[off])
            | (UInt32(padded[off + 1]) << 8)
            | (UInt32(padded[off + 2]) << 16)
            | (UInt32(padded[off + 3]) << 24)
    }
    return block
}

/// Pack a [UInt32] output state's first 8 words into 32 bytes (little-endian).
private func blake3OutputBytes(from state: [UInt32]) -> Data {
    var out = Data(count: 32)
    out.withUnsafeMutableBytes { (buf: UnsafeMutableRawBufferPointer) in
        for i in 0..<8 {
            let v = state[i]
            buf[i * 4 + 0] = UInt8(v & 0xFF)
            buf[i * 4 + 1] = UInt8((v >> 8) & 0xFF)
            buf[i * 4 + 2] = UInt8((v >> 16) & 0xFF)
            buf[i * 4 + 3] = UInt8((v >> 24) & 0xFF)
        }
    }
    return out
}

/// Compute BLAKE3(input) → 32 bytes. Handles inputs up to 64 bytes.
func blake3Hash(_ input: Data) -> Data {
    let block = blake3BlockWords(from: input)
    let flags: UInt32 = blake3CHUNK_START | blake3CHUNK_END | blake3ROOT
    let outputState = blake3Compress(
        cv: blake3IV,
        block: block,
        blockLen: UInt32(min(input.count, 64)),
        counter: 0,
        flags: flags
    )
    return blake3OutputBytes(from: outputState)
}

/// Compute BLAKE3.derive_key(context, keyMaterial) → 32 bytes.
///
/// This is BLAKE3's two-pass key derivation:
///   1. Hash the context string with DERIVE_KEY_CONTEXT flag → 32-byte context key
///   2. Compress the key material with DERIVE_KEY_MATERIAL flag using context key as CV
///
/// context must be a short ASCII string (≤ 64 bytes).
/// keyMaterial must be ≤ 64 bytes.
func blake3DeriveKey(context: String, keyMaterial: Data) -> Data {
    // Pass 1: hash the context string to get the chaining value (CV)
    let contextData = Data(context.utf8)
    let contextBlock = blake3BlockWords(from: contextData)
    let contextFlags: UInt32 = blake3CHUNK_START | blake3CHUNK_END | blake3ROOT | blake3DERIVE_KEY_CONTEXT
    let contextState = blake3Compress(
        cv: blake3IV,
        block: contextBlock,
        blockLen: UInt32(min(contextData.count, 64)),
        counter: 0,
        flags: contextFlags
    )
    // The first 8 words of the output form the derived CV
    let derivedCV = Array(contextState.prefix(8))

    // Pass 2: compress the key material using the derived CV
    let materialBlock = blake3BlockWords(from: keyMaterial)
    let materialFlags: UInt32 = blake3CHUNK_START | blake3CHUNK_END | blake3ROOT | blake3DERIVE_KEY_MATERIAL
    let outputState = blake3Compress(
        cv: derivedCV,
        block: materialBlock,
        blockLen: UInt32(min(keyMaterial.count, 64)),
        counter: 0,
        flags: materialFlags
    )
    return blake3OutputBytes(from: outputState)
}

private extension UInt32 {
    func rotateRight(_ n: Int) -> UInt32 {
        return (self >> n) | (self << (32 - n))
    }
}
