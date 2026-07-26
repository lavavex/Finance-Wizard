//
//  CategorySymbol.swift
//  FinanceWidget
//
//  Maps budget categories (and card names) to SF Symbols for the UI.
//

import Foundation

// Turns category / payment-method strings into SF Symbol names
enum CategorySymbol {
    // Symbol for a transaction’s budget category
    static func name(forCategory category: String) -> String {
        // Compare case-insensitively; categories from finance-sync are fairly stable
        switch category.lowercased() {
        case "gas (car)", "gas", "fuel":
            return "fuelpump.fill"
        case "dining", "restaurants", "food":
            return "fork.knife"
        case "groceries":
            return "cart.fill"
        case "subscriptions":
            return "repeat.circle.fill"
        case "shopping":
            return "bag.fill"
        case "travel", "flights", "hotels":
            return "airplane"
        case "car insurance", "insurance":
            return "car.fill"
        case "home internet", "internet", "utilities":
            return "wifi"
        case "personal care":
            return "heart.text.square.fill"
        case "miscellaneous", "misc", "other":
            return "ellipsis.circle.fill"
        case "coffee":
            return "cup.and.saucer.fill"
        default:
            // Unknown category — generic receipt
            return "doc.text.fill"
        }
    }

    // Optional: rough icon for a payment method / card row
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
