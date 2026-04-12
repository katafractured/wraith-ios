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
        case multiHopEntryNodeId = "com.katafract.wraith.multiHopEntryNodeId"
        case multiHopExitNodeId  = "com.katafract.wraith.multiHopExitNodeId"
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

    // MARK: - Raw data

    func save(_ data: Data, for key: Key) throws {
        // Always store as device-local (never iCloud-synced).
        // iCloud sync was removed in v139 due to stale-item auth loops.
        let query: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrAccount as String:        key.rawValue,
            kSecAttrAccessible as String:     kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
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

        // Remove any stale iCloud-synced copy left from the old sync feature.
        let staleQuery: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrAccount as String:        key.rawValue,
            kSecAttrSynchronizable as String: true,
        ]
        SecItemDelete(staleQuery as CFDictionary)
    }

    func readData(for key: Key) throws -> Data {
        // 1. Prefer device-local item (authoritative — written by current session).
        let localQuery: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrAccount as String:        key.rawValue,
            kSecReturnData as String:         true,
            kSecMatchLimit as String:         kSecMatchLimitOne,
            kSecAttrSynchronizable as String: false,
        ]
        var result: AnyObject?
        if SecItemCopyMatching(localQuery as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data {
            return data
        }

        // 2. Fall back to iCloud-synced item (migration path: users who had iCloud sync
        //    enabled before v139). Re-save as device-local so next read uses path 1.
        let iCloudQuery: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrAccount as String:        key.rawValue,
            kSecReturnData as String:         true,
            kSecMatchLimit as String:         kSecMatchLimitOne,
            kSecAttrSynchronizable as String: true,
        ]
        result = nil
        if SecItemCopyMatching(iCloudQuery as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data {
            try? save(data, for: key)   // migrate to device-local (also deletes iCloud copy)
            return data
        }

        throw KeychainError.itemNotFound
    }

    // MARK: - Delete

    func delete(for key: Key) {
        // Delete device-local item
        let localQuery: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrAccount as String:        key.rawValue,
            kSecAttrSynchronizable as String: false,
        ]
        SecItemDelete(localQuery as CFDictionary)
        // Also delete any iCloud-synced copy (cleanup)
        let iCloudQuery: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrAccount as String:        key.rawValue,
            kSecAttrSynchronizable as String: true,
        ]
        SecItemDelete(iCloudQuery as CFDictionary)
    }

    func deleteAll() {
        Key.allCases.forEach { delete(for: $0) }
    }
}

extension KeychainHelper.Key: CaseIterable {}
