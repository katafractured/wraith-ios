// KeychainHelper.swift
// WraithVPN
//
// Type-safe Keychain wrapper for storing the subscription token and WireGuard
// private key. Uses kSecClassGenericPassword items scoped to the app's bundle ID.

import Foundation
import Security

enum KeychainError: LocalizedError {
    case unexpectedStatus(OSStatus)
    case encodingFailed
    case itemNotFound

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let s): return "Keychain OSStatus \(s)"
        case .encodingFailed:          return "Data encoding failed"
        case .itemNotFound:            return "Item not found in Keychain"
        }
    }
}

final class KeychainHelper {

    // MARK: - Singleton

    static let shared = KeychainHelper()
    private init() {}

    // MARK: - Well-known keys

    enum Key: String {
        case subscriptionToken  = "com.katafract.wraith.subscriptionToken"
        case wireguardPrivKey   = "com.katafract.wraith.wireguardPrivateKey"
        case wireguardPubKey    = "com.katafract.wraith.wireguardPublicKey"
        case activePeerId       = "com.katafract.wraith.activePeerId"
        case tokenExpiresAt     = "com.katafract.wraith.tokenExpiresAt"
        case tokenPlan          = "com.katafract.wraith.tokenPlan"
        case tokenIsAdmin       = "com.katafract.wraith.tokenIsAdmin"
        case tokenIsFounder     = "com.katafract.wraith.tokenIsFounder"
        case wgConfig           = "com.katafract.wraith.wgConfig"
        case wgPeerId           = "com.katafract.wraith.wgPeerId"
        case wgNodeId           = "com.katafract.wraith.wgNodeId"
        case wgAssignedIP       = "com.katafract.wraith.wgAssignedIP"
        case wgExitIP           = "com.katafract.wraith.wgExitIP"
        case activeNodeId       = "com.katafract.wraith.activeNodeId"
        case activeRegion       = "com.katafract.wraith.activeRegion"
        // Multi-hop
        case multiHopGroupId    = "com.katafract.wraith.multiHopGroupId"
        case multiHopEntryPeerId = "com.katafract.wraith.multiHopEntryPeerId"
        case multiHopExitPeerId  = "com.katafract.wraith.multiHopExitPeerId"
        case multiHopEntryNodeId   = "com.katafract.wraith.multiHopEntryNodeId"
        case multiHopExitNodeId    = "com.katafract.wraith.multiHopExitNodeId"
        case multiHopEntryRegion   = "com.katafract.wraith.multiHopEntryRegion"
        case multiHopExitRegion    = "com.katafract.wraith.multiHopExitRegion"
        // Shadowsocks fallback
        case activeShadowsocksConfig = "com.katafract.wraith.activeShadowsocksConfig"
        case transportModePreference = "com.katafract.wraith.transportModePreference"
    }

    // MARK: - String convenience

    func save(_ value: String, for key: Key) throws {
        guard let data = value.data(using: .utf8) else { throw KeychainError.encodingFailed }
        try save(data, for: key)
    }

    func read(for key: Key) throws -> String {
        let data = try readData(for: key)
        guard let str = String(data: data, encoding: .utf8) else { throw KeychainError.encodingFailed }
        return str
    }

    func readOptional(for key: Key) -> String? {
        try? read(for: key)
    }

    // MARK: - Codable convenience

    func saveCodable<T: Encodable>(_ value: T, for key: Key) throws {
        let data = try JSONEncoder().encode(value)
        let str = String(data: data, encoding: .utf8) ?? ""
        try save(str, for: key)
    }

    func readCodable<T: Decodable>(_ type: T.Type, for key: Key) throws -> T? {
        guard let str = readOptional(for: key), let data = str.data(using: .utf8) else { return nil }
        return try JSONDecoder().decode(type, from: data)
    }

    // MARK: - Sync policy

    /// Auth/identity keys sync via iCloud Keychain so founders can enter a code once
    /// and have it available on all their Apple devices.
    /// WireGuard keys and per-device VPN state are always device-local.
    private static let syncedKeys: Set<Key> = [
        .subscriptionToken, .tokenPlan, .tokenExpiresAt, .tokenIsAdmin, .tokenIsFounder,
    ]

    private func isSynced(_ key: Key) -> Bool { Self.syncedKeys.contains(key) }

    // MARK: - Raw data

    func save(_ data: Data, for key: Key) throws {
        let synced = isSynced(key)
        let accessible: CFString = synced
            ? kSecAttrAccessibleAfterFirstUnlock          // iCloud-synced items can't use ThisDeviceOnly
            : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let query: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrAccount as String:        key.rawValue,
            kSecAttrAccessible as String:     accessible,
            kSecAttrSynchronizable as String: synced,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecItemNotFound {
            var insertQuery = query
            insertQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(insertQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.unexpectedStatus(updateStatus)
        }

        // Delete the opposite-sync-policy copy (handles policy migrations).
        let oppositeQuery: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrAccount as String:        key.rawValue,
            kSecAttrSynchronizable as String: !synced,
        ]
        SecItemDelete(oppositeQuery as CFDictionary)
    }

    func readData(for key: Key) throws -> Data {
        let synced = isSynced(key)
        let primaryQuery: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrAccount as String:        key.rawValue,
            kSecReturnData as String:         true,
            kSecMatchLimit as String:         kSecMatchLimitOne,
            kSecAttrSynchronizable as String: synced,
        ]
        var result: AnyObject?
        if SecItemCopyMatching(primaryQuery as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data {
            return data
        }

        // Fall back to opposite policy (handles devices with old items from before policy migration).
        let fallbackQuery: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrAccount as String:        key.rawValue,
            kSecReturnData as String:         true,
            kSecMatchLimit as String:         kSecMatchLimitOne,
            kSecAttrSynchronizable as String: !synced,
        ]
        result = nil
        if SecItemCopyMatching(fallbackQuery as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data {
            try? save(data, for: key)   // re-save under correct policy (also removes old copy)
            return data
        }

        throw KeychainError.itemNotFound
    }

    // MARK: - Delete

    func delete(for key: Key) {
        // Delete both synced and local copies to ensure clean state.
        for synced in [true, false] {
            let query: [String: Any] = [
                kSecClass as String:              kSecClassGenericPassword,
                kSecAttrAccount as String:        key.rawValue,
                kSecAttrSynchronizable as String: synced,
            ]
            SecItemDelete(query as CFDictionary)
        }
    }

    func deleteAll() {
        Key.allCases.forEach { delete(for: $0) }
    }
}

extension KeychainHelper.Key: CaseIterable {}
