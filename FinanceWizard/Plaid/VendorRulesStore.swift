//
//  VendorRulesStore.swift
//  Finance Wizard
//
//  Local “learn” rules: vendor (+ optional card) → category.
//  Applied on Plaid sync when a row is not user-locked.
//
//  Example: user sets “STARBUCKS” on Chase Sapphire → Dining.
//  Next sync of that merchant reuses the learned category.
//

import Foundation

/// One learned mapping from a merchant (and optional card) to a spend category.
struct VendorRule: Codable, Equatable, Sendable {
    /// Normalized vendor name (lowercased, trimmed) used as the lookup key.
    var vendorKey: String
    /// Empty string = any card; otherwise normalized payment method label.
    var paymentMethodKey: String
    /// App category name to apply (e.g. "Dining").
    var category: String
}

/// Persist and look up vendor learn-rules in UserDefaults.
enum VendorRulesStore {
    private static let key = "plaid.vendorRules"

    /// Load all saved rules, or empty array if none / corrupt data.
    static func load() -> [VendorRule] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let rules = try? JSONDecoder().decode([VendorRule].self, from: data) else {
            return []
        }
        return rules
    }

    /// Replace the entire rules list on disk.
    static func save(_ rules: [VendorRule]) {
        if let data = try? JSONEncoder().encode(rules) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Insert or update a rule for vendor (+ optional card-scoped payment method).
    /// - Parameters:
    ///   - vendor: Merchant name (will be normalized).
    ///   - paymentMethod: Card/account label, or nil for “any card.”
    ///   - category: Category to apply on future syncs.
    static func upsert(vendor: String, paymentMethod: String?, category: String) {
        let vKey = normalize(vendor)
        let pKey = paymentMethod.map { normalize($0) } ?? ""
        var rules = load()
        if let idx = rules.firstIndex(where: {
            $0.vendorKey == vKey && $0.paymentMethodKey == pKey
        }) {
            rules[idx].category = category
        } else {
            rules.append(
                VendorRule(
                    vendorKey: vKey,
                    paymentMethodKey: pKey,
                    category: category
                )
            )
        }
        save(rules)
    }

    /// Prefer card-scoped rule, then any-card rule.
    /// Returns nil if no rule matches (or vendor looks like a bill-pay code).
    static func match(vendor: String, paymentMethod: String) -> VendorRule? {
        let vKey = normalize(vendor)
        // Never apply learn-rules to ACH bill-pay codes (e.g. EPAY → Chase card)
        if isBillPayVendorKey(vKey) { return nil }
        let pKey = normalize(paymentMethod)
        let rules = load()
        if let exact = rules.first(where: { $0.vendorKey == vKey && $0.paymentMethodKey == pKey }) {
            return exact
        }
        return rules.first(where: { $0.vendorKey == vKey && $0.paymentMethodKey.isEmpty })
    }

    /// Drop learn rules that reclassified bill pays as spend (e.g. epay → Shopping).
    static func removeBillPayMisrules() {
        let cleaned = load().filter { !isBillPayVendorKey($0.vendorKey) }
        save(cleaned)
    }

    /// True for vendor keys that are really card bill-pay descriptors, not merchants.
    private static func isBillPayVendorKey(_ key: String) -> Bool {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return k == "epay" || k == "e-pay" || k == "epmt"
            || k.hasPrefix("payment thank you")
            || k.hasPrefix("mobile payment")
    }

    /// Canonical form for matching: trim whitespace, lowercase.
    private static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
