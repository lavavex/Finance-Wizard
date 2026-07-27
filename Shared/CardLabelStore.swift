//
//  CardLabelStore.swift
//  Finance Wizard
//
//  User-chosen display names for credit cards / payment methods.
//  Keys: "account:<plaid account_id>" or "method:<raw payment method string>".
//

import Foundation

enum CardLabelStore {
    private static let labelsKey = "card.customLabels"
    private static let productsKey = "card.productStyles"

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

    // MARK: - Card product art

    /// Explicit product pick, else infer from nickname / payment method text.
    static func product(
        accountId: String?,
        paymentMethod: String,
        displayName: String
    ) -> CardProduct {
        if let accountId, let raw = getProduct(key: accountKey(accountId)),
           let product = CardProduct(rawValue: raw) {
            return product
        }
        if let raw = getProduct(key: methodKey(paymentMethod)),
           let product = CardProduct(rawValue: raw) {
            return product
        }
        // Infer from nickname first (user typed “Chase Freedom”), then raw method
        let fromName = CardProduct.resolve(from: displayName)
        if fromName != .generic { return fromName }
        return CardProduct.resolve(from: paymentMethod)
    }

    static func setProduct(_ product: CardProduct?, accountId: String?, paymentMethod: String) {
        let key: String = {
            if let accountId, !accountId.isEmpty { return accountKey(accountId) }
            return methodKey(paymentMethod)
        }()
        if let product, product != .generic {
            setProductValue(product.rawValue, key: key)
        } else {
            removeProduct(key: key)
        }
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

    private static func productMap() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: productsKey) as? [String: String] ?? [:]
    }

    private static func getLabel(key: String) -> String? { labelMap()[key] }
    private static func getProduct(key: String) -> String? { productMap()[key] }

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

    private static func setProductValue(_ value: String, key: String) {
        var map = productMap()
        map[key] = value
        UserDefaults.standard.set(map, forKey: productsKey)
    }

    private static func removeProduct(key: String) {
        var map = productMap()
        map.removeValue(forKey: key)
        UserDefaults.standard.set(map, forKey: productsKey)
    }
}
