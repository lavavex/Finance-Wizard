//
//  CardLabelStore.swift
//  Finance Wizard
//
//  User-chosen display names for cards / payment methods.
//  Keys: "account:<plaid account_id>" or "method:<raw payment method string>".
//

import Foundation

enum CardLabelStore {
    private static let labelsKey = "card.customLabels"

    // MARK: - Display name

    /// Preferred label for a Plaid bank account.
    static func label(
        accountId: String,
        fallback: String
    ) -> String {
        if let custom = getLabel(key: accountKey(accountId)), !custom.isEmpty {
            return custom
        }
        return fallback
    }

    /// Preferred label for a transaction payment-method string.
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
        return fallback ?? paymentMethod
    }

    // MARK: - Write names

    static func setLabel(_ name: String?, accountId: String) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            removeLabel(key: accountKey(accountId))
        } else {
            setLabelValue(trimmed, key: accountKey(accountId))
        }
    }

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

    private static func accountKey(_ id: String) -> String { "account:\(id)" }
    private static func methodKey(_ method: String) -> String { "method:\(method)" }

    private static func labelMap() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: labelsKey) as? [String: String] ?? [:]
    }

    private static func getLabel(key: String) -> String? { labelMap()[key] }

    private static func setLabelValue(_ value: String, key: String) {
        var map = labelMap()
        map[key] = value
        UserDefaults.standard.set(map, forKey: labelsKey)
    }

    private static func removeLabel(key: String) {
        var map = labelMap()
        map.removeValue(forKey: key)
        UserDefaults.standard.set(map, forKey: labelsKey)
    }
}
