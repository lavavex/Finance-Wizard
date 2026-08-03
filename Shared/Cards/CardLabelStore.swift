//
//  CardLabelStore.swift
//  Finance Wizard
//
//  User-chosen display names for cards / payment methods.
//  Keys: "account:<plaid account_id>" or "method:<raw payment method string>".
//
//  Learning notes:
//  - UserDefaults is a simple key-value store for small settings (persists between launches).
//  - enum with only static members = namespace; no need to create a CardLabelStore() instance.
//  - private static hides helpers from other files.
//  - Optional String? means “maybe a name, maybe clear the label.”
//

import Foundation

/// Read/write nicknames for linked cards so UI can show “Travel Visa” instead of raw Plaid text.
enum CardLabelStore {
    /// UserDefaults key for the whole [storageKey: nickname] dictionary.
    private static let labelsKey = "card.customLabels"

    // MARK: - Display name

    /// Preferred label for a Plaid bank account.
    static func label(
        accountId: String,
        fallback: String
    ) -> String {
        // Custom nickname wins; otherwise show whatever the caller passed as fallback
        if let custom = getLabel(key: accountKey(accountId)), !custom.isEmpty {
            return custom
        }
        return fallback
    }

    /// Preferred label for a transaction payment-method string.
    /// Tries account id first (stable), then raw method string, then fallback.
    static func label(
        paymentMethod: String,
        accountId: String? = nil,
        fallback: String? = nil
    ) -> String {
        if let accountId, let custom = getLabel(key: accountKey(accountId)), !custom.isEmpty {
            return custom
        }
        if let custom = getLabel(key: methodKey(paymentMethod)), !custom.isEmpty {
            return custom
        }
        // ?? means “use paymentMethod when fallback is nil”
        return fallback ?? paymentMethod
    }

    // MARK: - Write names

    /// Save or clear a nickname for a Plaid account id.
    static func setLabel(_ name: String?, accountId: String) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            removeLabel(key: accountKey(accountId))
        } else {
            setLabelValue(trimmed, key: accountKey(accountId))
        }
    }

    /// Save or clear a nickname for a payment-method string key.
    static func setLabel(_ name: String?, paymentMethod: String) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            removeLabel(key: methodKey(paymentMethod))
        } else {
            setLabelValue(trimmed, key: methodKey(paymentMethod))
        }
    }

    /// Save nickname, preferring account id when available (stable across Sync renames).
    static func setLabel(_ name: String?, accountId: String?, paymentMethod: String) {
        if let accountId, !accountId.isEmpty {
            setLabel(name, accountId: accountId)
        } else {
            setLabel(name, paymentMethod: paymentMethod)
        }
    }

    // MARK: - Storage

    /// Prefix keys so account ids and method strings never collide in one map.
    private static func accountKey(_ id: String) -> String { "account:\(id)" }
    private static func methodKey(_ method: String) -> String { "method:\(method)" }

    /// Load the full nickname dictionary (or empty if never saved / wrong type).
    /// `as?` is a conditional cast: succeeds only when the value really is [String: String].
    private static func labelMap() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: labelsKey) as? [String: String] ?? [:]
    }

    private static func getLabel(key: String) -> String? { labelMap()[key] }

    /// Insert/update one entry and write the whole map back to UserDefaults.
    private static func setLabelValue(_ value: String, key: String) {
        var map = labelMap()
        map[key] = value
        UserDefaults.standard.set(map, forKey: labelsKey)
    }

    /// Delete one entry and persist the remaining map.
    private static func removeLabel(key: String) {
        var map = labelMap()
        map.removeValue(forKey: key)
        UserDefaults.standard.set(map, forKey: labelsKey)
    }
}
