//
//  PlaidKeychain.swift
//  Finance Wizard
//
//  Minimal Keychain helpers for secrets and access tokens.
//  Prefer Keychain over UserDefaults for API secrets and bank access tokens.
//

import Foundation
import Security

/// Thin wrapper around the iOS Keychain for Plaid secrets and access tokens.
enum PlaidKeychain {
    /// Groups all Finance Wizard Plaid Keychain items under one service.
    private static let service = "net.roberth.FinanceWizard.plaid"

    /// Save (or replace) a string secret under `account`.
    /// - Parameters:
    ///   - value: The secret string (e.g. access token).
    ///   - account: Keychain “account” field — key name within `service`.
    /// - Throws: `KeychainError` if the system Keychain refuses the write.
    static func set(_ value: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            // Readable after first unlock; this device only (not iCloud Keychain).
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        // Update in place, so a failed write leaves the existing secret intact.
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else {
            throw KeychainError.unhandled(updated)
        }
        let add = query.merging(attributes) { _, new in new }
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unhandled(status)
        }
    }

    /// Read a secret. Returns nil if missing or unreadable (not an error throw).
    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    /// Deletes every Finance Wizard Plaid Keychain item (API secret + access tokens).
    static func deleteAll() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Remove a secret if present. Ignores “not found” (safe to call repeatedly).
    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    enum KeychainError: LocalizedError {
        case unhandled(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unhandled(let status):
                return "Keychain error (\(status))"
            }
        }
    }
}
