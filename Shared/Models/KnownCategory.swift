//
//  KnownCategory.swift
//  Finance Wizard
//
//  General expense categories for Transactions, Budget, charts, and Sync.
//  These are NOT the same as card earn categories (see RewardCategory.swift).
//
//  Design goals:
//  • Enough buckets for a real monthly budget without exploding into PFC noise
//  • Stable display names (existing txs keep working)
//  • Aliases so “Gas”, “Medical”, etc. canonicalize for limits + pickers
//

import Foundation

/// Canonical general spend categories used across the app.
enum KnownCategory: String, CaseIterable, Identifiable, Codable {
    // Essentials / housing
    case housing = "Housing"
    case utilities = "Utilities"
    case homeInternet = "Home Internet"
    case carInsurance = "Car Insurance"

    // Day-to-day
    case groceries = "Groceries"
    case dining = "Dining"
    case gas = "Gas (Car)"
    case transit = "Transit"
    case shopping = "Shopping"

    // Lifestyle
    case entertainment = "Entertainment"
    case subscriptions = "Subscriptions"
    case travel = "Travel"
    case health = "Health"
    case personalCare = "Personal Care"
    case education = "Education"
    case pets = "Pets"
    case giftsDonations = "Gifts & Donations"

    // Catch-alls
    case fees = "Fees"
    case miscellaneous = "Miscellaneous"

    /// Card-line disbursement (Chase My Loan). Visible, but not Total Spend or Total paid.
    case loan = "Loan"
    /// Merchant refund / statement credit on a card (not earnings, not spend).
    case refund = "Refund"
    /// Apple Card monthly installment billing rows (original purchase already counted).
    case installment = "Installment"

    /// Bill pays — excluded from Total Spend / Budget spend.
    case creditCardPayment = "Credit Card Payment"

    var id: String { rawValue }

    /// SF Symbol via shared CategoryStyle helper.
    var systemImage: String {
        CategoryStyle.symbolName(for: rawValue)
    }

    /// Short help for Budget / category pickers.
    var budgetHint: String {
        switch self {
        case .housing: return "Rent, mortgage, HOA"
        case .utilities: return "Electric, water, gas, trash"
        case .homeInternet: return "Internet, cable, phone"
        case .carInsurance: return "Auto (and similar) insurance"
        case .groceries: return "Supermarkets, grocery delivery"
        case .dining: return "Restaurants, coffee, takeout"
        case .gas: return "Gas stations, EV charging"
        case .transit: return "Rideshare, transit, parking, tolls"
        case .shopping: return "Retail, Amazon, general merchandise"
        case .entertainment: return "Movies, concerts, hobbies, games"
        case .subscriptions: return "Streaming, software, memberships"
        case .travel: return "Flights, hotels, vacation"
        case .health: return "Doctor, pharmacy, dental, vision"
        case .personalCare: return "Salon, spa, gym, personal products"
        case .education: return "Tuition, courses, books, kids school"
        case .pets: return "Vet, pet food, pet supplies"
        case .giftsDonations: return "Gifts, charity, donations"
        case .fees: return "Bank fees, ATM, late fees"
        case .miscellaneous: return "Everything else"
        case .loan: return "My Loan / cash from a card’s credit line (not spend)"
        case .refund: return "Card credits and merchant refunds (not earnings)"
        case .installment: return "Apple Card monthly installment billings (not new spend)"
        case .creditCardPayment: return "Card bill payments (not spend)"
        }
    }

    /// Names for the Transactions category picker (includes bill pay).
    static var defaultNames: [String] {
        allCases.map(\.rawValue)
    }

    /// Spend categories only (excludes bill pays) — Budget limits + spend charts.
    static var spendNames: [String] {
        allCases.filter {
            $0 != .creditCardPayment && $0 != .loan && $0 != .refund && $0 != .installment
        }.map(\.rawValue)
    }

    /// Logical order for Budget “add limit” picker (essentials first).
    static var budgetPickerOrder: [KnownCategory] {
        [
            .housing, .utilities, .homeInternet, .carInsurance,
            .groceries, .dining, .gas, .transit, .shopping,
            .entertainment, .subscriptions, .travel,
            .health, .personalCare, .education, .pets, .giftsDonations,
            .fees, .miscellaneous
        ]
    }

    static var budgetPickerNames: [String] {
        budgetPickerOrder.map(\.rawValue)
    }

    /// Alternate labels that should resolve to a known category.
    private static let aliases: [String: KnownCategory] = {
        var map: [String: KnownCategory] = [:]
        func alias(_ keys: [String], _ cat: KnownCategory) {
            for k in keys { map[k] = cat }
        }
        alias(["housing", "rent", "mortgage", "hoa"], .housing)
        alias(["utilities", "utility", "electric", "water", "trash", "sewer"], .utilities)
        alias(["home internet", "internet", "cable", "phone", "mobile phone", "telecom", "phone & internet"], .homeInternet)
        alias(["car insurance", "auto insurance", "insurance"], .carInsurance)
        alias(["groceries", "grocery", "supermarket"], .groceries)
        alias(["dining", "restaurants", "restaurant", "food", "food and drink", "food & drink", "coffee", "fast food"], .dining)
        alias(["gas (car)", "gas", "fuel", "ev charging"], .gas)
        alias(["transit", "transportation", "transport", "rideshare", "parking", "tolls", "taxi", "uber", "lyft"], .transit)
        alias(["shopping", "retail", "merchandise", "general merchandise"], .shopping)
        alias(["entertainment", "movies", "music", "games", "hobbies"], .entertainment)
        alias(["subscriptions", "subscription", "streaming"], .subscriptions)
        alias(["travel", "flights", "flight", "hotels", "hotel", "airfare", "vacation"], .travel)
        alias(["health", "medical", "healthcare", "pharmacy", "dental", "vision", "doctor"], .health)
        alias(["personal care", "salon", "spa", "gym", "fitness", "wellness"], .personalCare)
        alias(["education", "tuition", "school", "books"], .education)
        alias(["pets", "pet", "veterinary", "vet"], .pets)
        alias(["gifts & donations", "gifts and donations", "gifts", "donations", "charity", "donation"], .giftsDonations)
        alias(["fees", "bank fees", "atm", "service fee"], .fees)
        alias(["miscellaneous", "misc", "other", "uncategorized", "general services"], .miscellaneous)
        alias(["loan", "my loan", "my chase loan"], .loan)
        alias(["refund", "statement credit"], .refund)
        alias(["installment", "installments"], .installment)
        alias(["interest", "interest charge"], .fees)
        alias(["debit", "daily cash adjustment"], .miscellaneous)
        alias([
            "credit card payment", "credit card payments",
            "card payment", "card payments"
        ], .creditCardPayment)
        return map
    }()

    /// Canonical name if this string matches a known category or alias (case-insensitive).
    static func canonicalName(for raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if let exact = allCases.first(where: { $0.rawValue.caseInsensitiveCompare(t) == .orderedSame }) {
            return exact.rawValue
        }
        let key = t.lowercased()
        if let alias = aliases[key] {
            return alias.rawValue
        }
        return nil
    }

    /// Resolve to a KnownCategory case when possible.
    static func match(for raw: String) -> KnownCategory? {
        guard let name = canonicalName(for: raw) else { return nil }
        return allCases.first { $0.rawValue == name }
    }
}
