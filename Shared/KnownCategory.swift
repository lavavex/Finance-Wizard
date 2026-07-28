//
//  KnownCategory.swift
//  Finance Wizard
//
//  **General** expense categories for Transactions, charts, and Sync classification.
//  These are NOT the same as Benefit/Reward earn categories (see RewardCategory.swift).
//
//  Where definitions live:
//  • General categories → this file (KnownCategory)
//  • Reward earn rates → RewardCategory.swift + CardProductCatalog / CardBenefitsStore
//

import Foundation

enum KnownCategory: String, CaseIterable, Identifiable, Codable {
    case dining = "Dining"
    case gas = "Gas (Car)"
    case groceries = "Groceries"
    case subscriptions = "Subscriptions"
    case shopping = "Shopping"
    case travel = "Travel"
    case carInsurance = "Car Insurance"
    case homeInternet = "Home Internet"
    case personalCare = "Personal Care"
    case creditCardPayment = "Credit Card Payment"
    case miscellaneous = "Miscellaneous"

    var id: String { rawValue }

    var systemImage: String {
        CategoryStyle.symbolName(for: rawValue)
    }

    /// Names for the Transactions category picker (includes bill pay).
    static var defaultNames: [String] {
        allCases.map(\.rawValue)
    }

    /// Spend categories only (excludes bill pays).
    static var spendNames: [String] {
        allCases.filter { $0 != .creditCardPayment }.map(\.rawValue)
    }

    /// Canonical name if this string matches a known category (case-insensitive).
    static func canonicalName(for raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return allCases.first { $0.rawValue.caseInsensitiveCompare(t) == .orderedSame }?.rawValue
    }
}
