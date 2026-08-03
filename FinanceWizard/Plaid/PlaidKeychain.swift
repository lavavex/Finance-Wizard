//
//  PlaidKeychain.swift
//  Finance Wizard
//
//  Minimal Keychain helpers for secrets and access tokens.
//
//  The iOS Keychain is a secure system store for passwords/tokens.
//  Prefer it over UserDefaults for anything secret (API secrets, bank access tokens).
//
//  SWIFT TERMS IN THIS FILE:
//  - enum with no cases used as a namespace: groups static methods (no instances).
//  - throws / try: Function can fail; caller must handle the error.
//  - guard ... else: Early-exit if a condition fails (keeps the happy path un-nested).
//  - Optional (String?): May be a value or nil (missing).
//  - CFDictionary / CFTypeRef: Core Foundation types used by the Security C API.
//  - LocalizedError: Protocol so errors show a user-facing errorDescription string.
//

import Foundation
// Security framework: Apple’s low-level Keychain API (C-style, not pure Swift).
import Security

/// Thin wrapper around the iOS Keychain for Plaid secrets and access tokens.
///
/// Using an enum with only static members is a common Swift pattern for a
/// “utility namespace” — you never create a `PlaidKeychain()` instance.
enum PlaidKeychain {
    /// Bundle-like service name that groups all our Keychain items together.
    private static let service = "net.roberth.FinanceWizard.plaid"

    /// Save (or replace) a string secret under `account`.
    /// - Parameters:
    ///   - value: The secret string (e.g. access token).
    ///   - account: Keychain “account” field — acts like a key name within `service`.
    /// - Throws: `KeychainError` if the system Keychain refuses the write.
    static func set(_ value: String, account: String) throws {
        // Convert String → Data (UTF-8 bytes) for Keychain storage.
        let data = Data(value.utf8)
        // Dictionary of Keychain query attributes. kSec* constants come from Security.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        // Delete existing then add (simplest update path — avoids separate “update” API).
        // as CFDictionary bridges Swift Dictionary to Core Foundation for the C API.
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        // Only readable after first device unlock; stays on this device (not iCloud Keychain).
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        // errSecSuccess means OSStatus == 0 (no error).
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
            // Ask the API to return the secret bytes.
            kSecReturnData as String: true,
            // At most one matching item.
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        // CFTypeRef? is an opaque Core Foundation pointer; we cast it to Data below.
        // &item is an inout parameter — the C API writes the result into our variable.
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        // Optional chaining / casting: only proceed if status OK and bytes decode as UTF-8.
        guard status == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
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

    /// Errors from Keychain operations.
    /// Nested enum: defined inside PlaidKeychain so call sites write `PlaidKeychain.KeychainError`.
    enum KeychainError: LocalizedError {
        /// Unexpected OSStatus from Security (OSStatus is a C integer error code).
        case unhandled(OSStatus)

        /// LocalizedError: optional message shown in alerts / error.localizedDescription.
        var errorDescription: String? {
            switch self {
            case .unhandled(let status):
                // Associated value: `status` is the OSStatus packed into this case.
                return "Keychain error (\(status))"
            }
        }
    }
}
