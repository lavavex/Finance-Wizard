//
//  CategoryStyle.swift
//  Finance Wizard
//
//  App-wide category colors inspired by Apple Card / Wallet spending colors.
//  Same category → same color in charts, lists, and transaction rows.
//
//  Apple Card reference (Wallet):
//    Red    = Health
//    Orange = Food & drink
//    Yellow = Shopping
//    Green  = Travel
//    Blue   = Transportation
//    Purple = Services
//    Pink   = Entertainment
//

import SwiftUI

// Shared look for budget categories (color + SF Symbol)
enum CategoryStyle {

    // MARK: - Apple Card–like palette (works in light & dark)

    /// Health
    static let health = Color(red: 1.00, green: 0.23, blue: 0.19)
    /// Food & drink
    static let foodAndDrink = Color(red: 1.00, green: 0.58, blue: 0.00)
    /// Shopping
    static let shopping = Color(red: 1.00, green: 0.80, blue: 0.00)
    /// Travel
    static let travel = Color(red: 0.20, green: 0.78, blue: 0.35)
    /// Transportation
    static let transportation = Color(red: 0.04, green: 0.52, blue: 1.00)
    /// Services
    static let services = Color(red: 0.69, green: 0.32, blue: 0.87)
    /// Entertainment
    static let entertainment = Color(red: 1.00, green: 0.18, blue: 0.33)
    /// Uncategorized / Other
    static let other = Color(red: 0.56, green: 0.56, blue: 0.58)

    // MARK: - Mapping

    /// Stable color for a category name (finance-sync labels + Apple Card groups)
    static func color(for category: String) -> Color {
        // Also accepts combined group display names from pie merge
        switch colorGroup(for: category) {
        case .foodAndDrink: return foodAndDrink
        case .shopping: return shopping
        case .travel: return travel
        case .transportation: return transportation
        case .services: return services
        case .entertainment: return entertainment
        case .health: return health
        case .other: return other
        }
    }

    /// SF Symbol for a category (same mapping as before, kept here for one import site)
    static func symbolName(for category: String) -> String {
        // Combined pie group labels
        switch normalize(category) {
        case "food & drink", "food and drink":
            return "fork.knife"
        case "shopping":
            return "bag.fill"
        case "travel":
            return "airplane"
        case "transportation":
            return "fuelpump.fill"
        case "services":
            return "repeat.circle.fill"
        case "entertainment":
            return "theatermasks.fill"
        case "health":
            return "heart.text.square.fill"
        case "other":
            return "ellipsis.circle.fill"
        default:
            break
        }

        switch normalize(category) {
        case let c where matches(c, ["gas (car)", "gas", "fuel"]):
            return "fuelpump.fill"
        case let c where matches(c, ["dining", "restaurants", "food", "food and drink", "food & drink"]):
            return "fork.knife"
        case let c where matches(c, ["shopping", "retail", "groceries", "grocery"]):
            return "bag.fill"
        case let c where matches(c, ["subscriptions", "subscription"]):
            return "repeat.circle.fill"
        case let c where matches(c, ["travel", "flights", "flight", "hotels", "hotel"]):
            return "airplane"
        case let c where matches(c, ["car insurance", "insurance"]):
            return "car.fill"
        case let c where matches(c, ["home internet", "internet", "utilities", "utility"]):
            return "wifi"
        case let c where matches(c, ["personal care", "health", "medical", "pharmacy"]):
            return "heart.text.square.fill"
        case let c where matches(c, ["entertainment", "movies", "music", "streaming"]):
            return "theatermasks.fill"
        case let c where matches(c, ["coffee"]):
            return "cup.and.saucer.fill"
        // Income categories (GET /api/income — Payroll, Direct Deposit, Interest, Refund, Other Income)
        case let c where matches(c, ["payroll", "paycheck", "salary", "wages"]):
            return "banknote.fill"
        case let c where matches(c, ["direct deposit", "mobile deposit", "check deposit"]):
            return "building.columns.fill"
        case let c where matches(c, ["interest"]):
            return "percent"
        case let c where matches(c, ["refund", "refunds", "return"]):
            return "arrow.uturn.backward.circle.fill"
        case let c where matches(c, ["other income", "income", "bonus", "promo"]):
            return "dollarsign.circle.fill"
        case let c where matches(c, ["miscellaneous", "misc", "other", "uncategorized"]):
            return "ellipsis.circle.fill"
        default:
            return "doc.text.fill"
        }
    }

    /// Colors for a list of category names (for chartForegroundStyleScale)
    static func colors(for categories: [String]) -> [Color] {
        categories.map { color(for: $0) }
    }

    // MARK: - Color groups (for combining pie slices)

    /// Apple Card color group id
    enum ColorGroup: String, CaseIterable {
        case foodAndDrink
        case shopping
        case travel
        case transportation
        case services
        case entertainment
        case health
        case other

        /// Label used when slices are merged (must map back through `color(for:)`)
        var displayName: String {
            switch self {
            case .foodAndDrink: return "Food & Drink"
            case .shopping: return "Shopping"
            case .travel: return "Travel"
            case .transportation: return "Transportation"
            case .services: return "Services"
            case .entertainment: return "Entertainment"
            case .health: return "Health"
            case .other: return "Other"
            }
        }
    }

    /// Which Apple Card color group a category belongs to
    static func colorGroup(for category: String) -> ColorGroup {
        let c = normalize(category)

        // Already-combined pie labels
        switch c {
        case "food & drink", "food and drink": return .foodAndDrink
        case "shopping": return .shopping
        case "travel": return .travel
        case "transportation": return .transportation
        case "services": return .services
        case "entertainment": return .entertainment
        case "health": return .health
        case "other": return .other
        default: break
        }

        if matches(c, [
            "dining", "food", "food and drink", "food & drink",
            "restaurants", "restaurant", "coffee"
        ]) { return .foodAndDrink }

        if matches(c, [
            "shopping", "retail", "merchandise", "groceries", "grocery"
        ]) { return .shopping }

        if matches(c, [
            "travel", "flights", "flight", "hotels", "hotel", "airfare", "vacation"
        ]) { return .travel }

        if matches(c, [
            "gas (car)", "gas", "fuel", "transportation", "transport",
            "transit", "rideshare", "parking", "car", "automotive"
        ]) { return .transportation }

        if matches(c, [
            "subscriptions", "subscription", "services", "service",
            "home internet", "internet", "utilities", "utility",
            "car insurance", "insurance", "phone", "telecom"
        ]) { return .services }

        if matches(c, [
            "entertainment", "movies", "music", "streaming", "games", "hobbies"
        ]) { return .entertainment }

        if matches(c, [
            "health", "medical", "pharmacy", "personal care", "fitness", "wellness"
        ]) { return .health }

        return .other
    }

    /// Merge category rows that share the same Apple Card color into one slice each.
    static func combineByColor(_ items: [CategorySpendSummary]) -> [CategorySpendSummary] {
        var spent: [ColorGroup: Double] = [:]
        var counts: [ColorGroup: Int] = [:]

        for item in items {
            let group = colorGroup(for: item.category)
            spent[group, default: 0] += item.spent
            counts[group, default: 0] += item.transactionCount
        }

        return spent.map { group, amount in
            CategorySpendSummary(
                category: group.displayName,
                spent: amount,
                transactionCount: counts[group] ?? 0
            )
        }
        .sorted { $0.spent > $1.spent }
    }

    // MARK: - Private

    private static func normalize(_ category: String) -> String {
        category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func matches(_ value: String, _ options: [String]) -> Bool {
        options.contains(value)
    }
}

// Back-compat wrapper so existing CategorySymbol call sites keep working
enum CategorySymbol {
    static func name(forCategory category: String) -> String {
        CategoryStyle.symbolName(for: category)
    }

    static func name(forPaymentMethod method: String) -> String {
        let m = method.lowercased()
        if m.contains("checking") || m.contains("savings") {
            return "building.columns.fill"
        }
        if m.contains("visa") || m.contains("freedom") || m.contains("prime")
            || m.contains("amex") || m.contains("mastercard") || m.contains("card") {
            return "creditcard.fill"
        }
        if m.contains("money") || m.contains("cash") {
            return "banknote.fill"
        }
        return "creditcard.fill"
    }
}
