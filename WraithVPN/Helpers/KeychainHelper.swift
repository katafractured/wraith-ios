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
        case wgConfig           = "com.katafract.wraith.wgConfig"
        case wgPeerId           = "com.katafract.wraith.wgPeerId"
        case wgNodeId           = "com.katafract.wraith.wgNodeId"
        case wgAssignedIP       = "com.katafract.wraith.wgAssignedIP"
        case wgExitIP           = "com.katafract.wraith.wgExitIP"
        case activeNodeId       = "com.katafract.wraith.activeNodeId"
        case activeRegion       = "com.katafract.wraith.activeRegion"
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
        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrAccount as String:      key.rawValue,
            kSecAttrAccessible as String:   kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        // Try update first
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecItemNotFound {
            // Insert
            var insertQuery = query
            insertQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(insertQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.unexpectedStatus(updateStatus)
        }
    }

    func readData(for key: Key) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            if status == errSecItemNotFound { throw KeychainError.itemNotFound }
            throw KeychainError.unexpectedStatus(status)
        }

        guard let data = result as? Data else { throw KeychainError.encodingFailed }
        return data
    }

    // MARK: - Delete

    func delete(for key: Key) {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: key.rawValue,
        ]
        SecItemDelete(query as CFDictionary)
    }

    func deleteAll() {
        Key.allCases.forEach { delete(for: $0) }
    }
}

extension KeychainHelper.Key: CaseIterable {}
