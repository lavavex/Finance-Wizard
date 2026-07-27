//
//  VendorRulesStore.swift
//  Finance Wizard
//
//  Local “learn” rules: vendor (+ optional card) → category / multiplier.
//  Applied on Plaid sync when a row is not user-locked.
//

import Foundation

struct VendorRule: Codable, Equatable, Sendable {
    var vendorKey: String
    /// Empty string = any card
    var paymentMethodKey: String
    var category: String
    var multiplier: Double
}

enum VendorRulesStore {
    private static let key = "plaid.vendorRules"

    static func load() -> [VendorRule] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let rules = try? JSONDecoder().decode([VendorRule].self, from: data) else {
            return []
        }
        return rules
    }

    static func save(_ rules: [VendorRule]) {
        if let data = try? JSONEncoder().encode(rules) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func upsert(vendor: String, paymentMethod: String?, category: String, multiplier: Double) {
        let vKey = normalize(vendor)
        let pKey = paymentMethod.map { normalize($0) } ?? ""
        var rules = load()
        if let idx = rules.firstIndex(where: {
            $0.vendorKey == vKey && $0.paymentMethodKey == pKey
        }) {
            rules[idx].category = category
            rules[idx].multiplier = multiplier
        } else {
            rules.append(
                VendorRule(
                    vendorKey: vKey,
                    paymentMethodKey: pKey,
                    category: category,
                    multiplier: multiplier
                )
            )
        }
        save(rules)
    }

    /// Prefer card-scoped rule, then any-card rule.
    static func match(vendor: String, paymentMethod: String) -> VendorRule? {
        let vKey = normalize(vendor)
        let pKey = normalize(paymentMethod)
        let rules = load()
        if let exact = rules.first(where: { $0.vendorKey == vKey && $0.paymentMethodKey == pKey }) {
            return exact
        }
        return rules.first(where: { $0.vendorKey == vKey && $0.paymentMethodKey.isEmpty })
    }

    private static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
